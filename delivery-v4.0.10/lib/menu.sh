#!/usr/bin/env bash
# 入口菜单只读取本地记录，不加载现场 Bash 配置，不探测远程节点。
# 这样尚未填写配置的用户也能查看状态或安全退出；状态不是实时健康检查。

# Return 0 for a readable object, 1 for a genuinely missing path, and 2 for
# an inaccessible/invalid path. Check ancestors before test -e: test -e alone
# also returns false for EACCES and must never be treated as an empty cluster.
status_read_error() {
    printf '状态未知：无法读取 %s（权限不足、路径不可访问或记录类型异常）；请由有权限的管理员核对原配置和记录，不要据此首装或删除数据。\n' "$1" >&2
}
status_readable_path() {
    local path="$1" kind="$2" parent current i
    local -a ancestors=()
    if [ -z "$path" ] || [[ "$path" = *$'\n'* ]]; then status_read_error "$path"; return 2; fi
    [[ "$path" = /* ]] || path="$PWD/$path"
    current="$path"
    while :; do
        ancestors+=("$current")
        parent=$(dirname -- "$current")
        [ "$parent" != "$current" ] || break
        current="$parent"
    done
    for ((i=${#ancestors[@]}-1; i>=0; i--)); do
        current="${ancestors[i]}"
        if [ ! -e "$current" ]; then
            if [ -L "$current" ]; then status_read_error "$current"; return 2; fi
            return 1
        fi
        if [ "$i" -gt 0 ]; then
            if [ ! -d "$current" ] || [ ! -x "$current" ]; then status_read_error "$current"; return 2; fi
        elif [ "$kind" = dir ]; then
            if [ ! -d "$current" ] || [ ! -r "$current" ] || [ ! -x "$current" ]; then status_read_error "$current"; return 2; fi
        elif [ ! -f "$current" ] || [ ! -r "$current" ]; then
            status_read_error "$current"; return 2
        fi
    done
    return 0
}

deployment_status() {
    local config="$1" base record status found=false readable=true rc line file
    printf '\n=== 本地部署记录（实时健康请使用 verify）===\n'
    if status_readable_path "$config" file; then
        printf '现场配置：%s\n' "$config"
    else
        rc=$?
        if [ "$rc" -eq 1 ]; then printf '现场配置：尚未生成\n'; else readable=false; fi
    fi
    # Do not source env. Default enumeration must check read/search permission
    # before globbing; a literal unmatched glob is not evidence of absence.
    local -a records=() receipt_status=()
    if [ -n "${STATUS_STATE_DIR:-}" ]; then
        records=("$STATUS_STATE_DIR" "${STATUS_STATE_DIR}.deployment" "${STATUS_STATE_DIR}.harbor.deployment" "${STATUS_STATE_DIR}.expansion" "${STATUS_STATE_DIR}.workflow")
    elif status_readable_path "$ROOT/state" dir; then
        records=("$ROOT"/state/*)
    else
        rc=$?
        [ "$rc" -ne 2 ] || readable=false
    fi
    for record in "${records[@]}"; do
        if ! [ -e "$record" ] && ! [ -L "$record" ] && [ -z "${STATUS_STATE_DIR:-}" ]; then continue; fi
        if status_readable_path "$record" dir; then :; else
            rc=$?; [ "$rc" -ne 2 ] || readable=false; continue
        fi
        base=$(basename "$record")
        case "$base" in
            *.workflow)
                found=true
                printf '分步记录：%s\n' "$record"
                for step in access prepare deps services-init services-verify harbor-install harbor-projects images-import images-verify k8s-install node-images-verify cluster-verify ledger; do
                    file="$record/$step.json"
                    if status_readable_path "$file" file; then
                        if line=$(jq -er 'select(type=="object" and (.stage|type=="string") and (.status|type=="string") and (.run|type=="string")) | [.stage,.status,.run]|join(" | ")' "$file" 2>/dev/null); then printf '%s\n' "$line"
                        else status_read_error "$file"; readable=false; fi
                    else rc=$?; [ "$rc" -ne 2 ] || readable=false; fi
                done;;
            *.expansion)
                found=true
                printf '未完成扩容：%s\n需人工核对运行记录和全部节点；不能直接续跑安装或删除。\n' "$record";;
            *.deployment)
                found=true
                if status_readable_path "$record/status" file; then
                    # Read at most two lines so a valid first value cannot hide
                    # a trailing corrupt value; writers create exactly one line.
                    if mapfile -t -n 2 receipt_status < "$record/status" 2>/dev/null; then
                        status=unknown
                        [ "${#receipt_status[@]}" -ne 1 ] || status="${receipt_status[0]}"
                    else
                        status_read_error "$record/status"; readable=false; status=unknown
                    fi
                else
                    rc=$?; [ "$rc" -ne 1 ] || status_read_error "$record/status"
                    readable=false; status=unknown
                fi
                case "$status" in
                    complete) status='已完成（需 verify 确认当前健康）';;
                    reset) status='已删除 K8s/etcd，可选择重新部署';;
                    running|interrupted) status='部署未完成；请先核对日志和现场，再选择对应维护操作';;
                    *)
                        printf '状态未知：部署状态记录为空、无法读取或值无效：%s；请核对原始回执，不能据此继续部署。\n' "$record/status" >&2
                        readable=false
                        status='状态未知；需人工核对原始回执';;
                esac
                printf '%s：%s\n记录位置：%s\n' "$base" "$status" "$record"
                if status_readable_path "$record/last-run" file; then
                    if line=$(head -n 1 "$record/last-run" 2>/dev/null); then printf '最近运行：%s\n' "$line"
                    else status_read_error "$record/last-run"; readable=false; fi
                else rc=$?; [ "$rc" -ne 2 ] || readable=false; fi;;
            *)
                if status_readable_path "$record/identity.json" file; then
                    found=true; printf '%s：已有受管集群记录\n' "$record"
                else rc=$?; [ "$rc" -ne 2 ] || readable=false; fi;;
        esac
    done
    if ! deployment_preparation_status "$config"; then readable=false; fi
    if [ "$found" = false ] && [ "$readable" = true ]; then
        printf '尚未发现部署记录；如使用自定义 STATE_DIR，请加 --state-dir 路径。此结果不代表现场没有集群或数据。\n'
    fi
    printf '提示：部署后请保留 cluster-vars.env、state/ 和 runs/。\n\n'
    [ "$readable" = true ]
}

deployment_menu() {
    local config="$1"
    deployment_status "$config" || :
    while :; do
        printf '%s\n' '1. 安装' '2. 查看状态' '3. 检查环境' '4. 添加 worker' '5. 维护与恢复' '6. 配置与高级操作' '7. 分步部署' '0. 退出（默认）'
        ask_default '请选择操作' 0
        case "$REPLY" in
            0) stage=exit; return;;
            1)
                printf '%s\n' '1. 使用已有配置范围（首次默认整套）' '2. 整套安装' '3. 仅安装 Harbor' '4. 复用仓库安装 K8s' '0. 返回'
                ask_valid '安装范围' 1 '0|1|2|3|4'
                case "$REPLY" in 0) continue;; 1) ;; 2) CLI_COMPONENTS=all;; 3) CLI_COMPONENTS=harbor;; 4) CLI_COMPONENTS=k8s;; esac
                [ -z "${CLI_COMPONENTS:-}" ] || export CLI_COMPONENTS
                stage=all; return;;
            2) deployment_status "$config" || :;;
            3) stage=check; return;;
            4) stage=add-workers; return;;
            5)
                printf '%s\n' '1. 继续上次部署（须有匹配回执）' '2. 删除 K8s/etcd（保留 Harbor；仍需确认串）' '3. 重新部署（保留基础环境）' '0. 返回'
                ask_valid '维护操作' 0 '0|1|2|3'
                case "$REPLY" in 1) stage=resume; return;; 2) stage=reset; return;; 3) stage=redeploy; return;; esac;;
            7)
                printf '%s\n' '1. SSH 接入' '2. 准备存储与内核' '3. 离线 OS 依赖' '4. NTP/NFS 初始化' '5. NTP/NFS 验收' '6. 安装 Harbor' '7. Harbor 项目' '8. 镜像导入' '9. 仓库镜像验收' '10. 安装 K8s' '11. 节点镜像拉取验收' '12. 生成环境台账' '13. 集群功能验收（含临时 Pod/PVC）' '0. 返回'
                ask_valid '分步操作' 0 '0|1|2|3|4|5|6|7|8|9|10|11|12|13'
                case "$REPLY" in
                    1) stage=access;; 2) stage=prepare;; 3) stage=deps;;
                    4) stage=services-init;; 5) stage=services-verify;; 6) stage=harbor-install;;
                    7) stage=harbor-projects;; 8) stage=images-import;; 9) stage=images-verify;;
                    10) stage=k8s-install;; 11) stage=node-images-verify;; 12) stage=ledger;; 13) stage=cluster-verify;; 0) continue;;
                esac
                return;;
            6)
                printf '%s\n' '1. 修改已有配置' '2. 生成配置预览' '3. 仅初始化环境（需已完成接入）' '4. 实时健康检查' '5. 查看执行计划（只读）' '0. 返回'
                ask_valid '高级操作' 0 '0|1|2|3|4|5'
                case "$REPLY" in 1) stage=edit; return;; 2) stage=render; return;; 3) stage=init; return;; 4) stage=verify; return;; 5) stage=plan; return;; esac;;
            *) printf '请输入菜单中的编号；回车退出，不会启动安装。\n';;
        esac
    done
}

# 只看本次配置路径绑定的索引；不用 source 配置，状态查询不会执行现场脚本。
# components 仅展示，不推断用户下一次命令的范围。实际安装仍执行 prepared_resolve。
deployment_preparation_status() (
    local config="$1" source index effective status rc source_digest effective_digest
    if status_readable_path "$config" file; then :; else
        rc=$?; [ "$rc" -eq 1 ] && return 0; return 1
    fi
    . "$ROOT/lib/prepared-config.sh"
    if ! source=$(prepared_source_path "$config" 2>/dev/null); then status_read_error "$config"; return 1; fi
    if ! index=$(prepared_index_path "$source"); then status_read_error "$ROOT/state/prepared"; return 1; fi
    if status_readable_path "$index" file; then :; else
        rc=$?
        if [ "$rc" -eq 1 ]; then
            printf '当前配置：尚无初始化记录；是否可首装仍须核对现有集群、数据和全部回执。\n'; return 0
        fi
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then printf '准备记录状态未知：需安装 jq 后查看；未判断是否完成。\n' >&2; return 1; fi
    if ! jq -e --arg source "$source" '.version==1 and .source==$source' "$index" >/dev/null 2>&1; then
        printf '准备记录状态未知：索引损坏或无法读取，请核对原运行记录。\n' >&2; return 1
    fi
    if ! status=$(jq -r '.status // "complete"' "$index" 2>/dev/null); then status_read_error "$index"; return 1; fi
    if [ "$status" = pending ]; then
        printf '当前配置：初始化未完成；核对日志与实际挂载后执行完整 init。\n运行记录：%s\n' "$(jq -r '.run // "未知"' "$index")"
        return
    fi
    if ! effective=$(jq -r '.effective // empty' "$index" 2>/dev/null); then status_read_error "$index"; return 1; fi
    if status_readable_path "$effective" file; then :; else
        rc=$?
        if [ "$rc" -eq 1 ]; then printf '准备记录已失效：生效快照丢失；先核对记录，已有集群走维护或扩容。\n'; fi
        return 1
    fi
    if ! source_digest=$(sha256_file "$source") || ! effective_digest=$(sha256_file "$effective"); then
        status_read_error "$source / $effective"; return 1
    fi
    if [ "$status" != complete ] ||
       [ "$source_digest" != "$(jq -r .source_sha256 "$index")" ] ||
       [ "$effective_digest" != "$(jq -r .effective_sha256 "$index")" ]; then
        printf '准备记录已失效：配置或快照变化/丢失；先核对记录，已有集群走维护或扩容。\n'; return 1
    fi
    printf '准备阶段：初始化已完成，可安装（仅适用于尚未部署的集群；已有回执以回执状态为准）。\n组件范围：%s\n生效配置：%s\n' "$(jq -r .components "$index")" "$effective"
)
