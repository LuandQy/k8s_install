#!/usr/bin/env bash
# Distributed read-only environment collection and deployment conflict gate.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# 扩容子流程始终保留人工恢复提示，其他入口按各自操作提供建议。
[ "${RECOVERY_CONTEXT:-}" = expansion ] || RECOVERY_CONTEXT=check
export RECOVERY_CONTEXT
. "$ROOT/lib/routes.sh"
. "$ROOT/lib/progress.sh"
env_file="$ROOT/cluster-vars.env"; extended=false; collect_only=false
while [ "$#" -gt 0 ]; do
    case "$1" in --env|--output) [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] || die "$1 需要参数值";; esac
    case "$1" in
        --env) env_file="$2"; shift 2;; --output) RUN_DIR="$2"; shift 2;;
        --extended) extended=true; shift;; --collect-only) collect_only=true; shift;;
        *) die '用法: check.sh --env 参数.env [--output 新目录] [--extended] [--collect-only]';;
    esac
done
load_env "$env_file"; new_run
mkdir "$RUN_DIR/reports"
# Child diagnostics are restricted logs; only progress and redacted summaries use fd 3.
exec 3>&2
check_phase() {
    CHECK_PHASE="$2"
    printf '%s\n' "$CHECK_PHASE" > "$RUN_DIR/reports/phase-$NODE_NAME"
    printf '[检查 %s][%s/6] %s\n' "$NODE_NAME" "$1" "$CHECK_PHASE" >&3
}
check_finish() {
    local rc=$? elapsed=$((SECONDS-CHECK_STARTED)) details='' temp
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        [ "$CHECK_STATUS" = blocked ] || CHECK_STATUS=failed
        details=$(progress_error_lines "$CHECK_LOG") || details=''
        [ -n "$details" ] || details='检测步骤未成功完成；请查看对应节点日志。'
        printf '[检查失败] %s；阶段=%s；退出码=%s；耗时=%ss\n' "$NODE_NAME" "$CHECK_PHASE" "$rc" "$elapsed" >&3
        printf '%s\n日志: %s\n' "$details" "$CHECK_LOG" >&3
    else
        printf '[检查完成] %s；状态=%s；耗时=%ss\n' "$NODE_NAME" "$CHECK_STATUS" "$elapsed" >&3
    fi
    temp=$(mktemp "$RUN_DIR/reports/.status-$NODE_NAME.XXXXXX")
    jq -n --arg node "$NODE_NAME" --arg phase "$CHECK_PHASE" --arg status "$CHECK_STATUS" \
        --argjson exit_code "$rc" --argjson elapsed "$elapsed" --arg log "$CHECK_LOG" --arg details "$details" \
        '{node:$node,phase:$phase,status:$status,exit_code:$exit_code,elapsed_seconds:$elapsed,log:$log,error_summary:$details}' > "$temp"
    mv "$temp" "$RUN_DIR/reports/status-$NODE_NAME.json"
    exit "$rc"
}
section_json() { awk -v begin="RISE_${1}_BEGIN" -v end="RISE_${1}_END" '$0==begin{show=1;next}$0==end{show=0;exit}show' "$2"; }
if [ "$extended" = true ]; then
    {
        cat <<'SH'
set -euo pipefail
umask 077
tmp=$(mktemp -d /tmp/rise-report.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
cat > collect.sh <<'RISE_COLLECTOR_EOF'
SH
        cat "$ROOT/env_check.sh"
        cat <<'SH'
RISE_COLLECTOR_EOF
RISE_REPORT_DIR="$tmp" RISE_COLLECT_ONLY=1 bash collect.sh > "$tmp/collector.log" 2>&1 || {
    rc=$?
    cat "$tmp/collector.log" >&2
    printf '[ERROR] 扩展环境采集器退出码 %s\n' "$rc" >&2
    exit "$rc"
}
reports=(env_report_*.log)
test "${#reports[@]}" -eq 1 && test -f "${reports[0]}"
grep -q '^SUMMARY_HEALTH_RESULT=' "${reports[0]}"
cat "${reports[0]}"
SH
    } > "$RUN_DIR/collector.sh"
fi
check_one() {
    parse_node "$1"
    local dir="$RUN_DIR/reports/$NODE_NAME" nfs=0 rport=0 actual os version ips key value
    mkdir "$dir"
    check_phase 1 'SSH/sudo 与系统、磁盘、运行时信息采集'
    if has_role registry; then rport="$HARBOR_PORT"; fi
    if [ "$COMPONENTS" != harbor ] && [ "$NFS_MODE" = new ] && [ "$NFS_NODE" = "$NODE_NAME" ]; then nfs=1; fi
    node_run "$ROOT/node_scripts/inspect.sh" "$rport" "$nfs" "$ENDPOINT_PORT" "$NFS_PATH" "$CLUSTER_NAME" > "$dir/identity.log"
    check_phase 2 '校验磁盘、挂载、路由及网卡报告格式'
    for key in BLOCKS MOUNTS ROUTES LINKS; do
        section_json "$key" "$dir/identity.log" > "$dir/$key.json"
        if ! jq -e 'type=="object" or type=="array"' "$dir/$key.json" >/dev/null; then
            printf '[ERROR] %s 的 %s 报告缺失或 JSON 格式无效\n' "$NODE_NAME" "$key" >&2
            return 1
        fi
    done
    check_phase 3 '比对架构、操作系统与节点 IP'
    actual="$(sed -n 's/^RISE_ARCH=//p' "$dir/identity.log")"
    case "$actual" in x86_64) actual=amd64;; aarch64) actual=arm64;; *) die "$NODE_NAME 无法识别架构";; esac
    [ "$actual" = "$NODE_ARCH" ] || echo 'RISE_CONFLICT=实际架构与配置不一致' >> "$dir/identity.log"
    ips=" $(sed -n 's/^RISE_IPS=//p' "$dir/identity.log") "
    [[ "$ips" = *" $NODE_ADDRESS "* && "$ips" = *" $NODE_INTERNAL "* ]] || echo 'RISE_CONFLICT=配置IP不属于目标节点' >> "$dir/identity.log"
    os="$(sed -n 's/^RISE_OS=//p' "$dir/identity.log")"; version="$(sed -n 's/^RISE_OS_VERSION=//p' "$dir/identity.log")"
    case "$NODE_OS" in
        ubuntu-*) if [ "$os" != ubuntu ] || [[ "$NODE_OS" != *"-$version-"* ]]; then echo 'RISE_CONFLICT=实际OS与依赖包不匹配' >> "$dir/identity.log"; fi;;
        kylin-*) if [ "$os" != kylin ] || ! grep -q '^RISE_OS_DETAIL=.*Halberd' "$dir/identity.log"; then echo 'RISE_CONFLICT=需核对麒麟V10SP3-2403版本' >> "$dir/identity.log"; fi;;
    esac
    check_phase 4 '检查网络重叠及已有组件冲突'
    route_conflicts "$dir/ROUTES.json" >> "$dir/identity.log"
    local mid uuid hostname conflicts
    mid="$(sed -n 's/^RISE_MACHINE_ID=//p' "$dir/identity.log")"
    uuid="$(sed -n 's/^RISE_UUID=//p' "$dir/identity.log")"; hostname="$(sed -n 's/^RISE_HOSTNAME=//p' "$dir/identity.log")"
    [ -n "$mid" ] && [ -n "$hostname" ] || die "$NODE_NAME 身份采集不完整"
    conflicts="$(sed -n 's/^RISE_CONFLICT=//p' "$dir/identity.log" | jq -Rsc 'split("\n")|map(select(length>0))')"
    jq -n --arg name "$NODE_NAME" --arg ip "$NODE_INTERNAL" --arg arch "$actual" --arg mid "$mid" --arg uuid "$uuid" --arg hostname "$hostname" --argjson conflicts "$conflicts" \
       '{name:$name,ip:$ip,arch:$arch,machine_id:$mid,uuid:$uuid,hostname:$hostname,conflicts:$conflicts}' > "$dir/summary.json"
    check_phase 5 '扩展环境诊断'
    if [ "$extended" = true ]; then node_run "$RUN_DIR/collector.sh" > "$dir/environment.log"; fi
    check_phase 6 '汇总身份与安装阻塞项'
    if [ "$collect_only" = false ] && [ "$(jq '.conflicts|length' "$dir/summary.json")" -gt 0 ]; then
        CHECK_STATUS=blocked
        jq -r '.conflicts[] | "[ERROR] 安装阻塞: "+.' "$dir/summary.json" >&2; return 1
    fi
    CHECK_STATUS=passed
    [ "$(jq '.conflicts|length' "$dir/summary.json")" = 0 ] || CHECK_STATUS=collected_with_conflicts
    log "$NODE_NAME 检查完成"
}
pids=(); failed=0
mapfile -t check_nodes < <(active_node_lines)
total=${#check_nodes[@]}; completed=0
printf '[只读检查] 共 %s 个节点；并发上限 %s；报告: %s\n' "$total" "$SSH_PARALLEL" "$RUN_DIR" >&3
wait_batch() {
    local pid last=$SECONDS finished
    for pid in "${pids[@]}"; do
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$((SECONDS-last))" -ge "${PROGRESS_HEARTBEAT_SECONDS:-15}" ]; then
                finished=$(find "$RUN_DIR/reports" -maxdepth 1 -name 'status-*.json' -type f | wc -l | tr -d ' ')
                printf '[检查进行中] 已完成 %s/%s 个节点；仍在等待采集，阶段见 reports/phase-节点名\n' "$finished" "$total" >&3
                last=$SECONDS
            fi
            sleep "${PROGRESS_POLL_INTERVAL:-0.2}"
        done
        if ! wait "$pid"; then failed=1; fi
        completed=$((completed+1))
    done
    pids=()
}
for line in "${check_nodes[@]}"; do
    name=${line%%|*}
    (
        set -e
        NODE_NAME="$name"; CHECK_PHASE='启动检查'; CHECK_STATUS=failed; CHECK_STARTED=$SECONDS
        CHECK_LOG="$RUN_DIR/reports/worker-$name.log"
        trap check_finish EXIT
        check_one "$line"
    ) > "$RUN_DIR/reports/worker-$name.log" 2>&1 &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$SSH_PARALLEL" ]; then wait_batch; fi
done
[ "${#pids[@]}" -eq 0 ] || wait_batch
shopt -s nullglob
summaries=("$RUN_DIR"/reports/*/summary.json)
if [ "${#summaries[@]}" -gt 0 ]; then jq -s . "${summaries[@]}" > "$RUN_DIR/summary.json"
else printf '[]\n' > "$RUN_DIR/summary.json"; failed=1; fi
: > "$RUN_DIR/global-errors.jsonl"
for field in machine_id uuid hostname; do
    if jq -e --arg key "$field" 'group_by(.[$key]) | any(.[]; length>1 and (.[0][$key]|length)>0)' "$RUN_DIR/summary.json" >/dev/null; then
        log "发现重复 ${field}，请检查克隆节点"; failed=1
        jq -n --arg field "$field" '{code:"duplicate_node_identity",field:$field,message:"多个节点身份重复，请检查克隆节点"}' >> "$RUN_DIR/global-errors.jsonl"
    fi
done
jq -r '(["name","ip","arch","hostname","conflicts"]|@csv),(.[]|[.name,.ip,.arch,.hostname,(.conflicts|join(";"))]|@csv)' "$RUN_DIR/summary.json" > "$RUN_DIR/summary.csv"
statuses=("$RUN_DIR"/reports/status-*.json)
if [ "${#statuses[@]}" -gt 0 ]; then jq -s . "${statuses[@]}" > "$RUN_DIR/check-nodes.json"
else printf '[]\n' > "$RUN_DIR/check-nodes.json"; failed=1; fi
jq -s . "$RUN_DIR/global-errors.jsonl" > "$RUN_DIR/global-errors.json"
jq -n --argjson code "$failed" --argjson expected "$total" --argjson collect_only "$collect_only" \
    --slurpfile nodes "$RUN_DIR/check-nodes.json" --slurpfile errors "$RUN_DIR/global-errors.json" \
    '{schema:1,exit_code:$code,expected_nodes:$expected,collect_only:$collect_only,nodes:$nodes[0],global_errors:$errors[0]}' > "$RUN_DIR/checks.json"
jq -r '(["node","status","phase","exit_code","elapsed_seconds","error_summary","log"]|@csv),(.nodes[]|[.node,.status,.phase,.exit_code,.elapsed_seconds,.error_summary,.log]|@csv)' "$RUN_DIR/checks.json" > "$RUN_DIR/checks.csv"
printf '[检查汇总] 节点 %s/%s；退出码 %s；详细结果: %s/checks.json\n' "$completed" "$total" "$failed" "$RUN_DIR" >&3
log "环境报告: $RUN_DIR"
exit "$failed"
