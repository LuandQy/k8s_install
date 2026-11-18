#!/usr/bin/env bash
# 统一交付入口：先选择操作，再按需配置，最后执行原有安全校验与部署阶段。
set -euo pipefail
CLI_MODE=false
if [ "${1:-}" = artifact-sha256 ]; then
    shift
    exec bash "$(cd "$(dirname "$0")" && pwd)/lib/artifact-sha256.sh" "$@"
fi
if [ "${1:-}" = cli ]; then CLI_MODE=true; shift; fi
if [ "${1:-}" = web-executor ]; then
    shift
    command -v python3 >/dev/null || { printf '[ERROR] 本机 Web 执行器需要 Python 3；未执行安装。\n' >&2; exit 1; }
    exec python3 "$(cd "$(dirname "$0")" && pwd)/web/executor.py" "$@"
fi
if [ "${1:-}" = web ]; then
    shift
    command -v python3 >/dev/null || { printf '[ERROR] 本地 Web 配置工作台需要 Python 3；未执行安装。\n' >&2; exit 1; }
    exec python3 "$(cd "$(dirname "$0")" && pwd)/web/server.py" "$@"
fi
if [ "${1:-}" = preflight ]; then
    shift
    command -v python3 >/dev/null || { printf '[ERROR] 本机只读预检需要 python3；未执行任何安装。\n' >&2; exit 1; }
    exec python3 "$(cd "$(dirname "$0")" && pwd)/lib/local-preflight.py" "$@"
fi
if [ "${1:-}" = bootstrap ]; then shift; exec bash "$(cd "$(dirname "$0")" && pwd)/bootstrap/install.sh" "$@"; fi
if [ "${1:-}" = redeploy ]; then shift; exec bash "$(cd "$(dirname "$0")" && pwd)/redeploy.sh" "$@"; fi
if [ "${1:-}" = reset ]; then shift; exec bash "$(cd "$(dirname "$0")" && pwd)/reset.sh" "$@"; fi
if [ "${1:-}" = add-workers ]; then shift; exec bash "$(cd "$(dirname "$0")" && pwd)/scale-worker.sh" "$@"; fi
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
. "$ROOT/lib/render.sh"
. "$ROOT/lib/artifact.sh"
. "$ROOT/lib/pki.sh"
. "$ROOT/lib/wizard.sh"
. "$ROOT/lib/cluster-state.sh"
. "$ROOT/lib/resume.sh"
. "$ROOT/lib/redeploy.sh"
. "$ROOT/lib/progress.sh"
. "$ROOT/lib/images.sh"
. "$ROOT/lib/menu.sh"
. "$ROOT/lib/prepared-config.sh"
. "$ROOT/lib/plan.sh"
. "$ROOT/lib/workflow.sh"
. "$ROOT/lib/post-verify.sh"
. "$ROOT/lib/config-output.sh"
# 帮助文本集中在此，避免把整页说明塞进单行 case 分支。
usage() {
    cat <<'USAGE'
用法: bash deploy.sh [操作] [--env 文件] [-y] [--output 新目录]
推荐：sudo bash deploy.sh cli → 安装 → 向导/复用配置 → 确认后自动完成全流程。
cli：显式 CLI 入口；cli --auto-default 使用已有配置的非交互默认执行；--step <阶段> 可从任意已完成阶段边界续跑。
artifact-sha256 --file /绝对路径：本地流式摘要（与 Web 执行器按钮对齐），不连接节点。
web --data-dir 项目外专用目录 [--port 8765] [--executor-socket 路径]：普通用户启动本机 Web；默认配置模式，显式连接执行器后支持首装。
web-executor：管理员启动本机受限执行器；参数见 bash deploy.sh web-executor --help 与 docs/web-deployment.md。
config-check --env 文件 [--json]：仅校验可信 Bash env，输出公开参数，不写状态、不连接节点。
plan --env 文件 --json：schema_version=1 静态计划；不是执行授权，不表示环境可部署。
--components all|harbor|k8s：整套部署、仅仓库、复用仓库安装 K8s。
--skip-image-import：Harbor 不导入镜像；K8s 安装始终只读仓库。
无参数：先显示操作菜单；回车退出，不会启动安装。
-y, --yes：无阶段时执行 all；指定阶段时仅执行该阶段。包含 Harbor 的安装须提供 HARBOR_PASSWORD；仅 K8s 复用仓库不强制。
bootstrap [--with-sshpass]：安装控制端离线依赖，无需先填写集群配置（Ubuntu 24.04 amd64 root）。
plan --env 文件：只读列出拓扑、阶段、依赖和限制；不连接节点、不写运行目录、不安装。
render --wizard：向导生成配置并预览，不进入安装菜单。
preflight --output 新目录：本机只读检测及离线 APT 模拟；生成配置草案、计划和阻塞清单，不安装。
阶段: preflight bootstrap status plan render check access prepare deps services-init services-verify harbor-install harbor-projects images-import images-verify k8s-install node-images-verify cluster-verify ledger install resume verify all
access：全节点 SSH/sudo 接入；支持 bootstrap/key/password，不修改 sshd。
services-init / services-verify：NTP/NFS 初始化与验收，要求 prepare/deps 已完成。
node-images-verify：K8s 安装后逐节点通过 CRI 拉取并核对摘要，保留缓存。
cluster-verify：按 CLUSTER_VERIFY_MODE=selected-node|cross-node 执行 Pod DNS/TLS、Service 和本地 PVC 验收；跨节点暂要求同架构，成功按 UID 回收，无需 Harbor 密码。
REGISTRY_MODE=external-harbor：配 HARBOR_ADDRESS/公开 HARBOR_CA，仅 COMPONENTS=k8s，不把仓库主机列入 NODES，不支持安装/项目初始化/镜像导入。
ledger [--output 新目录]：仅汇总本地记录，导出 XLSX/JSON/HTML/CSV；Python 3.7+，不需要 root/密码。
resume：核对部署记录后重跑；旧版 CA 路径失败可用 resume --from-run 原运行目录
status [--state-dir 路径]：只读查看本地记录，不加载配置或连接节点；须有记录读取权限，无权限/损坏时返回非零并报告状态未知。
--versions：列出离线包支持的 Kubernetes 版本；--kk-versions：列出 KubeKey 版本。
--debug：输出 DEBUG、完整命令追踪与失败位置；日志不脱敏，可能包含凭据。
--log-level quiet|info|debug：日志级别，默认 info；quiet 只输出错误。
重新部署: ./deploy.sh redeploy [--kubernetes 版本] [--artifact 归档] [--preview]
删除: ./deploy.sh reset --preview；实际 reset 默认清空 etcd 数据，--purge-etcd 仅兼容旧命令（需交互确认）。
扩容: ./deploy.sh add-workers --nodes workers.env [--state-dir state/rise] [--preview] [-y]
静默模式禁止格式化，数据盘策略须为 existing 或 native。
USAGE
}
legacy_run=
NONINTERACTIVE="${NONINTERACTIVE:-false}"
stage=menu
step_option=''
auto_default=false
if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then stage="$1"; shift; fi
env_file="$ROOT/cluster-vars.env"
explicit_env=false
output_json=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --state-dir|--components|--from-run|--env|--output|--log-level|--step)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] || die "$1 需要参数值";;
    esac
    case "$1" in
    --state-dir) STATUS_STATE_DIR="$2"; shift 2;;
    --components) CLI_COMPONENTS="$2"; export CLI_COMPONENTS; shift 2;;
    --skip-image-import) CLI_IMPORT_IMAGES=false; export CLI_IMPORT_IMAGES; shift;;
    --skip-post-verify) SKIP_POST_VERIFY=true; export SKIP_POST_VERIFY; shift;;
    --from-run) legacy_run="$2"; shift 2;;
    --step) step_option="$2"; shift 2;;
    --auto-default) auto_default=true; cli_noninteractive=true; shift;;
    --env) env_file="$2"; explicit_env=true;shift 2;; --output) RUN_DIR="$2";shift 2;;
    --non-interactive) cli_noninteractive=true; [ "$stage" != menu ] || stage=all; shift;;
    -y|--yes) cli_noninteractive=true; [ "$stage" != menu ] || stage=all; shift;;
    --wizard) force_wizard=true; shift;;
    --json) output_json=true; shift;;
    --debug) RISE_LOG_LEVEL=debug; export RISE_LOG_LEVEL; shift;;
    --log-level) RISE_LOG_LEVEL="$2"; export RISE_LOG_LEVEL; shift 2;;
    --versions) supported_kubernetes_versions; exit 0;;
    --kk-versions) supported_kubekey_versions; exit 0;;
    -h|--help) usage; exit 0;;
    *) die '用法: deploy.sh {render|check|init|deps|install|resume|redeploy-run|verify|all} --env 文件 [--output 新目录] [--non-interactive]';;
esac; done
case "$RISE_LOG_LEVEL" in quiet|info|debug) ;; *) die 'RISE_LOG_LEVEL 必须为 quiet/info/debug';; esac
if [ -n "$step_option" ]; then stage="$step_option"; fi
if [ "$auto_default" = true ]; then
    cli_noninteractive=true
    [ "$stage" != menu ] || stage=all
fi
export RISE_LOG_LEVEL
# --debug/--log-level 在参数解析后生效；子脚本会因继承的变量自行开启追踪。
log_debug_apply_trace
[ "$RISE_LOG_LEVEL" != debug ] || log_debug '调试模式已开启：日志包含完整命令与敏感值，不做脱敏'
# 菜单和本地状态必须先于 load_env / new_run，退出不会产生配置或节点操作。
[ "$output_json" = false ] || [[ "$stage" = plan || "$stage" = config-check ]] || die '--json 仅支持 plan/config-check，不会执行安装'
from_menu=false
if [ "$stage" = status ]; then deployment_status "$env_file"; exit 0; fi
if [ "$stage" = menu ]; then
    deployment_menu "$env_file"
    [ "$stage" != exit ] || exit 0
    from_menu=true
fi
if [ "$from_menu" = true ]; then
    case "$stage" in
        edit) wizard_edit "$env_file"; exit 0;;
        reset|redeploy)
            # 只有用户确实传入 --env 才转发；默认配置不应成为覆盖回执的显式参数。
            if [ "$explicit_env" = true ]; then exec bash "$ROOT/$stage.sh" --env "$env_file"; fi
            exec bash "$ROOT/$stage.sh";;
        add-workers)
            wizard_select_state
            workers_file="$ROOT/workers.$(date +%Y%m%dT%H%M%S).$$.env"
            wizard_workers "$WIZARD_STATE_DIR" "$workers_file"
            [ -f "$workers_file" ] || exit 0
            exec bash "$ROOT/scale-worker.sh" --nodes "$workers_file" --state-dir "$WIZARD_STATE_DIR";;
    esac
fi
if [ "$stage" = plan ] || [ "$stage" = config-check ]; then
    [ "${force_wizard:-false}" != true ] || die "$stage 不运行配置向导；请先执行 render --wizard"
    [ -z "$legacy_run" ] || die '--from-run 仅用于 resume'
    load_env "$env_file"
    [ "$COMPONENTS" != all ] || [ "$IMPORT_IMAGES" = true ] || die '整套安装不能跳过镜像导入'
    if [ "$stage" = config-check ]; then
        if [ "$output_json" = true ]; then config_report_json config-check
        else printf '配置校验通过；仅校验可信 env 的参数，未检查节点或授权安装。\n'; fi
    elif [ "$output_json" = true ]; then deployment_plan_json
    else deployment_plan; fi
    exit 0
fi
case "$stage" in render|check|access|init|prepare|deps|services-init|services-verify|node-images-verify|cluster-verify|ledger|harbor|harbor-install|harbor-projects|images-import|images-verify|k8s|k8s-install|install|resume|redeploy-run|verify|all) ;; *) die '部署阶段无效，请使用 --help';; esac
if [ "${cli_noninteractive:-false}" = true ]; then
    [ -f "$env_file" ] || die '静默模式需要已有配置，请先通过向导或模板生成 cluster-vars.env'
elif [ "${force_wizard:-false}" = true ] || { [ "$from_menu" = true ] && [ "$stage" != resume ]; }; then
    wizard_setup "$env_file"
fi
if [ "$stage" = ledger ]; then
    load_env "$env_file"
    WF_FINGERPRINT=$(workflow_fingerprint)
    new_run; ledger_build; exit
fi
# New installs use explicit stages. Legacy maintenance keeps its receipt format.
if [ "${DELIVERY_STEP:-false}" != true ]; then
    case "$stage" in
        access|init|prepare|deps|services-init|services-verify|node-images-verify|cluster-verify|harbor|harbor-install|harbor-projects|images-import|images-verify|k8s|k8s-install|all|install)
            [ -z "$legacy_run" ] || die '--from-run 仅用于旧版 resume'
            load_env "$env_file"; workflow_main "$stage"; exit;;
        resume)
            load_env "$env_file"
            if [ -d "$STATE_DIR.workflow" ]; then
                [ -z "$legacy_run" ] || die '新分步记录不能导入旧版运行目录'
                workflow_main resume; exit
            fi;;
    esac
fi
# 只让安装类操作自动读取初始化快照。预览/检查仍读取用户文件，便于核对修改。
# resume 有自己的受保护部署回执，不使用准备阶段的快照替代它。
# 修改后重新加载与解析快照；在创建运行目录、读取密码和节点修改之前可安全取消。
while :; do
PREPARED_FOUND=false
load_env "$env_file"
if [ "${DELIVERY_STEP:-false}" != true ] && { [ "$stage" = all ] || [ "$stage" = install ] || [ "$stage" = deps ]; }; then
    prepared_resolve "$env_file"
    if [ "$PREPARED_FOUND" = true ]; then load_env "$PREPARED_ENV"; fi
fi
if [ "$stage" = resume ]; then
    if [ "$explicit_env" = false ] && [ -z "${CLI_COMPONENTS:-}" ] && [ ! -d "${STATE_DIR}.deployment" ] && [ -d "${STATE_DIR}.harbor.deployment" ]; then COMPONENTS=harbor; fi
    load_maintenance_env "$explicit_env"
fi
if [ "${cli_noninteractive:-false}" != true ] && [ "${NONINTERACTIVE:-false}" != true ]; then
    case "$stage" in
        all|install|init|resume|redeploy-run)
            wizard_summary
            if [ "$stage" = resume ] || [ "$stage" = redeploy-run ]; then
                ask_valid '1 开始执行；0 取消' 0 '0|1'
            else ask_valid '1 开始执行；2 修改原配置；0 取消' 0 '0|1|2'; fi
            case "$REPLY" in
                0) printf '已取消，未执行节点操作。\n'; exit 0;;
                2) wizard_edit "$env_file"; continue;;
            esac;;
    esac
fi
break
done
[ "$COMPONENTS" != all ] || [ "$IMPORT_IMAGES" = true ] || die '整套安装不能跳过镜像导入'
export COMPONENTS IMPORT_IMAGES

[ "$VALIDATION_SCOPE" = cluster ] || die '部署入口不能使用仅 worker 校验范围'
[ "${cli_noninteractive:-false}" = false ] || NONINTERACTIVE=true
export NONINTERACTIVE
# 完整初始化已经成功时，“安装集群”接着安装，不再重复选择或格式化磁盘。
if [ "$PREPARED_FOUND" = true ] && [ "$stage" = all ]; then stage=install; fi
if [ "$COMPONENTS" != harbor ] && { [ "$stage" = install ] || [ "$stage" = all ]; } && [ "$(cat "${STATE_DIR}.deployment/status" 2>/dev/null || true)" = reset ]; then
    log '检测到已重置集群，转入保留基础环境的重新部署流程'
    redeploy_args=(--env "$ENV_FILE")
    [ "${cli_noninteractive:-false}" != true ] || redeploy_args+=(-y)
    exec bash "$ROOT/redeploy.sh" "${redeploy_args[@]}"
fi
case "$stage" in render|check|init|deps|install|resume|redeploy-run|verify|all) ;; *) die '部署阶段无效';; esac
if [ "$NONINTERACTIVE" = true ]; then
    silent_preflight
elif [ "$stage" = all ] || [ "$stage" = install ] || [ "$stage" = resume ] || [ "$stage" = redeploy-run ] || [ "$stage" = init ]; then
    wizard_credentials
fi
if [ "$stage" = verify ] && [ "$COMPONENTS" = harbor ]; then
    if [ -z "${HARBOR_PASSWORD:-}" ] && [ "$NONINTERACTIVE" != true ]; then ask_secret HARBOR_PASSWORD 'Harbor 密码（隐藏输入）: '; fi
    validate_password
fi
new_run
progress_step 1/5 "范围=${COMPONENTS}；检查部署状态和环境"
if [ "$stage" = render ]; then render_configs; log "配置预览: $RUN_DIR"; exit; fi
if [ "$stage" = check ]; then RUN_DIR="$RUN_DIR/check" exec bash "$ROOT/check.sh" --env "$ENV_FILE" --extended; fi
if [ "$stage" = init ]; then RUN_DIR="$RUN_DIR/init" exec bash "$ROOT/init.sh" all --env "$ENV_FILE"; fi
linux_root
if [ "$stage" = install ] || [ "$stage" = resume ] || [ "$stage" = redeploy-run ] || [ "$stage" = all ]; then
    [ "$COMPONENTS" = harbor ] || [ ! -e "$STATE_DIR/identity.json" ] || die '此集群已有交付状态，扩容请使用 add-workers，不能重新安装'
fi
controller_lock
assert_no_pending_expansion
if [ "$stage" = all ] || [ "$stage" = install ] || [ "$stage" = deps ] || [ "$stage" = resume ] || [ "$stage" = redeploy-run ]; then
    preflight_artifact
fi
RECEIPT=$(component_receipt_dir)
REUSE_HARBOR=false
if [ "$COMPONENTS" != harbor ] && { [ "$stage" = install ] || [ "$stage" = all ]; } && [ -d "$STATE_DIR.harbor" ]; then
    component_verify_harbor_state
    REUSE_HARBOR=true
fi
if [ "$stage" = resume ]; then REUSE_HARBOR=$(cat "$RECEIPT/reuse-harbor" 2>/dev/null || printf false); fi
export REUSE_HARBOR
DEPLOYMENT_ID="rise-$(date +%Y%m%dT%H%M%S)-$$"
if [ "$stage" = redeploy-run ]; then
    redeploy_check_reset
    redeploy_check_foundation
elif [ "$stage" = resume ]; then
    [ -d "$RECEIPT" ] || [ -n "$legacy_run" ] || die '没有部署记录；旧版失败需指定 --from-run 原运行目录'
else
    [ -z "$legacy_run" ] || die '--from-run 仅用于 resume'
    if [ "$stage" = install ] || [ "$stage" = all ]; then
        [ ! -e "$RECEIPT" ] || die '已有未完成部署记录，请使用 ./deploy.sh resume'
    fi
fi
if [ "$stage" = all ] && [ "$COMPONENTS" != k8s ] && [ "$REUSE_HARBOR" != true ]; then
    RECOVERY_CONTEXT=init; export RECOVERY_CONTEXT
    ERROR_PHASE="初始化节点（SSH、磁盘、内核）"
    validate_password; choose_kk
    RUN_DIR="$RUN_DIR/init" bash "$ROOT/init.sh" all --env "$ENV_FILE"
    load_env "$RUN_DIR/init/effective.env"
fi
# 初始化已经返回成功。此后环境采集/入口连通性失败属于检查阶段，
# 不能沿用初始化上下文，更不能据此建议格式化或重新初始化节点。
RECOVERY_CONTEXT=check; export RECOVERY_CONTEXT
ERROR_PHASE="安装前环境与入口检查"
[ "$COMPONENTS" = harbor ] || check_external_endpoint
if [ "$stage" = install ] || [ "$stage" = resume ] || [ "$stage" = redeploy-run ] || [ "$stage" = all ]; then
    choose_kk
    [ "$COMPONENTS" = k8s ] || validate_password
    collection_scope="$COMPONENTS"; [ "$REUSE_HARBOR" != true ] || collection_scope=all
    if [ "$stage" = resume ] || [ "$stage" = redeploy-run ]; then
        CLI_COMPONENTS="$collection_scope" RUN_DIR="$RUN_DIR/check" bash "$ROOT/check.sh" --env "$ENV_FILE" --collect-only || die '续跑环境采集失败'
    else
        if [ "$COMPONENTS" = k8s ] || [ "$REUSE_HARBOR" = true ]; then
            CLI_COMPONENTS="$collection_scope" RUN_DIR="$RUN_DIR/check" bash "$ROOT/check.sh" --env "$ENV_FILE" --collect-only || die '环境采集失败'
            component_check_existing_report
        else
        RUN_DIR="$RUN_DIR/check" bash "$ROOT/check.sh" --env "$ENV_FILE" || die "安装前检查失败，详见 $RUN_DIR/check"
        fi
    fi
fi
if [ -n "${PREPARED_IDENTITY_FILE:-}" ]; then
    component_compare_prepared_identity "$PREPARED_IDENTITY_FILE" "$RUN_DIR/check/summary.json"
fi
progress_step 2/5 '校验离线依赖、证书和原部署记录' 
if [ "$stage" = deps ] || [ "$stage" = install ] || [ "$stage" = resume ] || [ "$stage" = redeploy-run ] || [ "$stage" = all ]; then
    if [ "$stage" = resume ] || [ "$stage" = redeploy-run ]; then
        stage_tools
        LIVE_RENDER=true render_configs
        if [ -n "$legacy_run" ]; then resume_import_legacy "$legacy_run"; legacy_run=; fi
        if [ "$stage" = redeploy-run ]; then
            redeploy_check_plan; redeploy_check_report
        else
            resume_check_plan; resume_check_report
        fi
    fi
    if [ "$COMPONENTS" = k8s ] || [ "$REUSE_HARBOR" = true ]; then
        LIVE_RENDER=true render_configs
        component_preflight_registry
    fi
    RECOVERY_CONTEXT=deps; export RECOVERY_CONTEXT
    ERROR_PHASE="准备离线依赖与仓库"
    nfs_preflight
    if [ "${DELIVERY_STEP:-false}" != true ]; then prepare_dependencies; fi
fi
if [ "$stage" = deps ]; then log "依赖准备完成: $RUN_DIR"; exit; fi
verify_cluster() {
    local line found=false expected_count=0 report="$RUN_DIR/cluster-nodes.json"
    while IFS= read -r line; do
        parse_node "$line"
        if has_role control_plane; then
            node_run "$ROOT/node_scripts/verify-cluster.sh" > "$report" 2> "$RUN_DIR/cluster-verify.log" ||
                die "集群基础验收失败，查看 $RUN_DIR/cluster-verify.log。处理后运行 ./deploy.sh verify"
            found=true
            break
        fi
    done < <(active_node_lines)
    [ "$found" = true ] || die '没有控制平面'
    while IFS= read -r line; do
        parse_node "$line"
        if has_role control_plane || has_role worker; then
            expected_count=$((expected_count + 1))
            jq -e --arg name "$NODE_NAME" --arg arch "$NODE_ARCH" \
                --arg version "$KUBE_VERSION" --arg ip "$NODE_INTERNAL" '
                any(.items[];
                    .metadata.name == $name and
                    .status.nodeInfo.architecture == $arch and
                    .status.nodeInfo.kubeletVersion == $version and
                    any(.status.addresses[]; .type == "InternalIP" and .address == $ip))
                ' "$report" >/dev/null ||
                die "节点 $NODE_NAME 验收失败。预期 $KUBE_VERSION / $NODE_ARCH / ${NODE_INTERNAL}，实际结果见 $report"
        fi
    done < <(active_node_lines)
    jq -e --argjson count "$expected_count" '.items | length == $count' "$report" >/dev/null ||
        die "集群节点数与配置不符，预期 $expected_count 个。实际结果见 $report"
    log "基础验收通过：$expected_count 个节点 Ready，版本 ${KUBE_VERSION}，架构、内网 IP、CoreDNS 和 Calico 就绪"
}
if [ "$stage" = verify ]; then
    if [ "$COMPONENTS" = harbor ]; then
        LIVE_RENDER=true render_configs
        progress_run 'Harbor 验收' "$RUN_DIR/harbor-verify.log" bash "$ROOT/lib/harbor.sh" "$RUN_DIR/harbor-settings.json" --health
    else verify_cluster; fi
    exit
fi
check_work_disk "$WORK_DIR"
while IFS= read -r line; do
    parse_node "$line"; local_path='-'; nfs_path='-'
    if [ "$LOCAL_STORAGE" = true ] && { has_role control_plane || has_role worker; }; then local_path="$LOCAL_PATH"; fi
    if [ "$COMPONENTS" != harbor ] && [ "$NFS_MODE" = new ] && [ "$NFS_NODE" = "$NODE_NAME" ]; then nfs_path="$NFS_PATH"; fi
    if [ "${DELIVERY_STEP:-false}" = true ]; then
        need_nfs=0; [ "$nfs_path" = - ] || need_nfs=1
        node_run "$ROOT/node_scripts/deps.sh" preinstalled - "$need_nfs" || die "$NODE_NAME 依赖状态变化，请核对 deps 阶段"
    fi
    effective_roles=$(component_effective_roles "$NODE_ROLES")
    node_run "$ROOT/node_scripts/verify-init.sh" "$NODE_DATA" "$HARBOR_SOURCE_DIR" "$effective_roles" "$local_path" "$nfs_path" "$NODE_DATA_MODE" || die "$NODE_NAME 初始化验收失败，请核对数据策略 ${NODE_DATA_MODE}、挂载 $NODE_DATA 和组件目录链接"
done < <(active_node_lines)
stage_tools
LIVE_RENDER=true render_configs
progress_step 3/5 '核验准备结果与 Harbor'
# Registry preflight ran before dependency/node mutations.
if [ "$COMPONENTS" = k8s ]; then cp "$RUN_DIR/preflight-settings.json" "$RUN_DIR/harbor-settings.json"; fi
if [ "$stage" = resume ] || [ "$stage" = redeploy-run ]; then
    if [ -n "$legacy_run" ]; then resume_import_legacy "$legacy_run"; fi
    if [ "$stage" = redeploy-run ]; then
        redeploy_check_plan; redeploy_check_report
        redeploy_new_receipt
    else
        resume_check_plan
    fi
else
    resume_save_receipt "$RUN_DIR/check/summary.json"
    resume_marker create
fi
printf '%s\n' "$RUN_DIR" > "$RECEIPT/last-run"
printf 'running\n' > "$RECEIPT/status"
trap resume_capture_exit EXIT
component_update_controller_hosts
playbook=$(component_choose_playbook)
args=(run --workdir "$WORK_DIR" "$playbook" --project-addr "$ROOT/kk-project" -i "$RUN_DIR/inventory.yaml" -c "$RUN_DIR/config.yaml")
[ -z "$ARTIFACT_FILE" ] || args+=(-a "$ARTIFACT_FILE")
RECOVERY_CONTEXT=deploy; export RECOVERY_CONTEXT
ERROR_PHASE="准备根 CA"
pki_stage_root
ERROR_PHASE="执行 KubeKey 部署"
progress_step 4/5 "执行 KubeKey（${COMPONENTS}）；任务进度见下方"
kk_ssh_preflight "$RUN_DIR/check/summary.json"
if progress_run "KubeKey $COMPONENTS 部署" "$RUN_DIR/kubekey.log" "$KK" "${args[@]}"; then
    :
else
    if [ "$COMPONENTS" = all ] && { [ "$HARBOR_HTTP" = true ] || [ -s "$(jq -r .ca_file "$RUN_DIR/harbor-settings.json")" ]; }; then
        if progress_run '保留已经就绪的 Harbor 状态' "$RUN_DIR/harbor-partial-verify.log" bash "$ROOT/lib/harbor.sh" "$RUN_DIR/harbor-settings.json" --health; then
            HARBOR_IMAGES_VERIFIED=false component_record_harbor
            log 'Harbor 健康状态已独立保存；镜像完整性仍需后续校验'
        fi
    fi
    die "部署失败；使用 ./deploy.sh resume --components $COMPONENTS 重试，日志: $RUN_DIR/kubekey.log"
fi
ERROR_PHASE="部署验收与保存状态"
progress_step 5/5 '执行组件验收并保存状态'
if [ "$COMPONENTS" = harbor ]; then
    progress_run 'Harbor 健康、TLS 和认证验收' "$RUN_DIR/harbor-verify.log" bash "$ROOT/lib/harbor.sh" "$RUN_DIR/harbor-settings.json" --health || die 'Harbor 验收失败'
    HARBOR_IMAGES_VERIFIED="$IMPORT_IMAGES" component_record_harbor
else
    verify_cluster
    record_cluster_state
    if [ "$COMPONENTS" = all ]; then HARBOR_IMAGES_VERIFIED=true component_record_harbor; fi
    if [ "$stage" = redeploy-run ]; then workflow_sync_and_post_verify "$RUN_DIR/check/summary.json"; fi
fi
printf 'complete\n' > "$RECEIPT/status"
log "部署流程完成: $RUN_DIR"

# 成功摘要只含运维所需信息，不打印密码或证书内容。
printf '\n交付结果：%s / Kubernetes %s\n' "$COMPONENTS" "$KUBE_VERSION"
while IFS= read -r line; do
    parse_node "$line"
    printf '  %-20s %-16s %s\n' "$NODE_NAME" "$NODE_ADDRESS" "$NODE_ROLES"
done < <(active_node_lines)
printf 'Harbor：%s:%s（用户 admin；密码为本次输入值）\n' "$HARBOR_DOMAIN" "$HARBOR_PORT"
printf '状态记录：%s\n下一步：验证业务网络和 PVC 读写；保留 state/ 与 runs/。\n' "$STATE_DIR"
