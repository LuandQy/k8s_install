#!/usr/bin/env bash
# SSH, storage and kernel preparation. Does not install Kubernetes.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# 扩容子流程始终保留人工恢复提示，其他入口按各自操作提供建议。
[ "${RECOVERY_CONTEXT:-}" = expansion ] || RECOVERY_CONTEXT=init
export RECOVERY_CONTEXT
. "$ROOT/lib/wizard.sh"
. "$ROOT/lib/disks.sh"
. "$ROOT/lib/storage-ui.sh"
. "$ROOT/lib/artifact.sh"
. "$ROOT/lib/access.sh"
. "$ROOT/lib/prepared-config.sh"
stage=all
if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then stage="$1";shift;fi
env_file="$ROOT/cluster-vars.env"
while [ "$#" -gt 0 ]; do case "$1" in --env) env_file="$2";shift 2;; --output) RUN_DIR="$2";shift 2;; --non-interactive) cli_noninteractive=true;shift;; *) die '用法: init.sh {keys|storage|kernel|all} --env 文件';; esac; done
case "$stage" in keys|storage|kernel|all) ;; *) die '初始化阶段无效';; esac
load_env "$env_file"
# 记录初始化开始时的用户配置摘要，防止执行期间被改写后错误绑定快照。
initial_source_sha=$(sha256_file "$ENV_FILE")
[ "${cli_noninteractive:-false}" = false ] || NONINTERACTIVE=true
export NONINTERACTIVE
ERROR_PHASE="初始化前置检查"
linux_root; controller_lock; new_run
assert_no_pending_expansion
preflight_artifact
# worker 扩容只准备新节点，不改变原集群配置的准备索引。
# 其他初始化（包括单阶段）必须先作废旧成功标记，失败时保持 pending。
if [ "$VALIDATION_SCOPE" = cluster ]; then prepared_invalidate "$ENV_FILE"; fi
full_nodes="$NODES"
if [ "${DELIVERY_ACCESS_READY:-false}" != true ] && { [ "$stage" = keys ] || [ "$stage" = all ]; }; then
    ERROR_PHASE="验证 SSH 与配置免密"
    # Low-level initialization and worker expansion use the same authentication
    # and key-conflict policy as the public access stage. Keep their existing
    # component/new-worker scope, then restore the complete effective topology.
    # Run in this shell: hidden password prompts export credentials needed by
    # the following preparation steps. The normal workflow checked all nodes.
    NODES=$(active_node_lines)
    access_run || die '初始化接入检查失败；保留接入日志，未继续存储或内核初始化'
    NODES="$full_nodes"
fi
if [ "$stage" = storage ] || [ "$stage" = all ]; then
    ERROR_PHASE="检查和初始化存储"
    nfs_preflight
    # Check every node before any destructive operation.
    RUN_DIR="$RUN_DIR/precheck" bash "$ROOT/check.sh" --env "$ENV_FILE"
    selected_nodes=''
    while IFS= read -r line; do
        parse_node "$line"
        reports="$RUN_DIR/precheck/reports/$NODE_NAME"
        disk_candidates "$reports/BLOCKS.json" > "$RUN_DIR/$NODE_NAME.candidates"
        show_storage_overview "$NODE_NAME" "$NODE_ADDRESS" "$reports/BLOCKS.json" "$reports/MOUNTS.json" "$RUN_DIR/$NODE_NAME.candidates"
        recommendation=$(recommended_storage_mode "$reports/BLOCKS.json" "$reports/MOUNTS.json")
        printf '编号/设备路径：新盘 GPT/ext4 后挂载；existing：复用已挂载数据盘；native：不建软链接。\n'
        while :; do
            if [ "$NODE_DATA_MODE" = auto ]; then
                default_mode=''
                if [ "$recommendation" = native ]; then
                    log '仅检测到系统盘，推荐 native：保留原生数据目录，不做软链接'
                    default_mode=native
                elif [ "$recommendation" = existing ]; then default_mode=existing; fi
                prompt "输入空盘编号/设备路径、existing（独立挂载盘）或 native（不做软链接）${default_mode:+ [$default_mode]}: "
                REPLY="${REPLY:-$default_mode}"
                if [ "$REPLY" = existing ]; then
                    NODE_DATA_MODE=existing
                    NODE_DEVICE=''
                elif [ "$REPLY" = native ]; then
                    NODE_DATA_MODE=native
                else
                    [ -s "$RUN_DIR/$NODE_NAME.candidates" ] || die '没有候选空盘，请人工准备挂载盘后使用 existing'
                    NODE_DATA_MODE=format
                    if [[ "$REPLY" =~ ^[1-9][0-9]*$ ]]; then NODE_DEVICE="$(sed -n "${REPLY}p" "$RUN_DIR/$NODE_NAME.candidates" | cut -f1)"; else NODE_DEVICE="$REPLY"; fi
                fi
            fi
            if [ "$NODE_DATA_MODE" = existing ] && [ "$recommendation" = native ]; then
                log '仅有系统盘，没有独立数据挂载点；使用 native 模式，跳过无意义的同盘软链接'
                NODE_DATA_MODE=native
            fi
            if [ "$NODE_DATA_MODE" = native ]; then
                NODE_DEVICE=''
                log "${NODE_NAME}：保留 Docker/containerd/kubelet/Harbor 原生目录；根盘最低可用空间 ${MIN_ROOT_FREE_GIB} GiB"
            fi
            confirmation='-'
            if [ "$NODE_DATA_MODE" = existing ]; then
                if ! select_storage_path existing; then NODE_DATA_MODE=auto; continue; fi
            fi
            if [ "$NODE_DATA_MODE" = format ]; then
                candidate="$(awk -F '\t' -v device="$NODE_DEVICE" '$1==device' "$RUN_DIR/$NODE_NAME.candidates")"
                [ -n "$candidate" ] || die '未选择合法候选整盘'
                size="$(printf '%s' "$candidate" | cut -f2)"
                if ! select_storage_path format; then NODE_DATA_MODE=auto; continue; fi
                show_format_confirmation "$NODE_NAME" "$NODE_ADDRESS" "$NODE_DEVICE" "$size" "$(printf '%s' "$candidate" | cut -f3)" "$(printf '%s' "$candidate" | cut -f4)" "$NODE_DATA"
                prompt "请输入 FORMAT:$NODE_DEVICE:$size 确认（回车或其他输入取消）: "
                confirmation="$REPLY"
                [ "$confirmation" = "FORMAT:$NODE_DEVICE:$size" ] || die '已取消格式化'
            fi
            break
        done
        printf '%s\n' "$confirmation" > "$RUN_DIR/$NODE_NAME.confirmation"
        row="$NODE_NAME|$NODE_ADDRESS|$NODE_INTERNAL|$NODE_USER|$NODE_PORT|$NODE_ARCH|$NODE_OS|$NODE_ROLES|$NODE_CONNECTION|${NODE_DATA%/}|$NODE_DATA_MODE|$NODE_DEVICE|$NODE_PASS_ENV"
        selected_nodes="${selected_nodes}${row}
"
    done < <(active_node_lines)
    # Save selected paths before mutations, so partial failure does not lose choices.
    cp "$ENV_FILE" "$RUN_DIR/selected.env"
    printf '\nNODES=%q\n' "$selected_nodes" >> "$RUN_DIR/selected.env"
    effective_nodes=''
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        parse_node "$line"
        node_run "$ROOT/node_scripts/storage.sh" "$NODE_DATA_MODE" "$NODE_DATA" "${NODE_DEVICE:--}" "$(cat "$RUN_DIR/$NODE_NAME.confirmation")" "$HARBOR_SOURCE_DIR" "$(component_effective_roles "$NODE_ROLES")" "$MIN_ROOT_FREE_GIB" | tee "$RUN_DIR/$NODE_NAME.storage.log"
        effective_mode=existing; [ "$NODE_DATA_MODE" != native ] || effective_mode=native
        effective_nodes="$effective_nodes$NODE_NAME|$NODE_ADDRESS|$NODE_INTERNAL|$NODE_USER|$NODE_PORT|$NODE_ARCH|$NODE_OS|$NODE_ROLES|$NODE_CONNECTION|$NODE_DATA|$effective_mode|$NODE_DEVICE|$NODE_PASS_ENV
"
    done <<< "$selected_nodes"
    NODES="$effective_nodes"
    roots="$(node_lines | cut -d'|' -f10 | sort -u)"
    if [ "$(printf '%s\n' "$roots" | wc -l | tr -d ' ')" = 1 ] && [ "$LOCAL_PATH" = /data/local-pv ]; then LOCAL_PATH="$roots/local-pv"; fi
    while IFS= read -r line; do
        parse_node "$line"
        if [ "$NODE_CONNECTION" = local ] && [ "$NODE_DATA_MODE" != native ] && [ "$WORK_DIR" = /data/rise-deploy ]; then WORK_DIR="$NODE_DATA/rise-deploy"; fi
        if [ "$NFS_MODE" = new ] && [ "$NFS_NODE" = "$NODE_NAME" ] && [ "$NFS_PATH" = /data/nfs ]; then NFS_PATH="$NODE_DATA/nfs"; fi
    done < <(active_node_lines)
fi
# 存储选择只处理当前组件涉及的节点，但生效配置必须保留完整拓扑。
# 例如仅初始化 k8s 时，独立 registry 行仍用于后续渲染和仓库校验。
# 按节点名合并，保留原顺序与非活动节点；不能用子集直接覆盖完整 NODES。
if [ "$stage" = storage ] || [ "$stage" = all ]; then
    merged_nodes=''
    while IFS= read -r original_row; do
        [ -n "$original_row" ] || continue
        node_name="${original_row%%|*}"
        replacement=$(printf '%s\n' "$effective_nodes" | awk -F '|' -v name="$node_name" '$1==name {print;exit}')
        merged_nodes="${merged_nodes}${replacement:-$original_row}
"
    done <<< "$full_nodes"
    NODES="$merged_nodes"
fi
if [ "$stage" = kernel ] || [ "$stage" = all ]; then
    ERROR_PHASE="初始化内核参数"
    while IFS= read -r line; do parse_node "$line"; node_run "$ROOT/node_scripts/kernel.sh" | tee "$RUN_DIR/$NODE_NAME.kernel.log"; done < <(active_node_lines)
    ERROR_PHASE="预装 K8s 节点 nerdctl 及配置"
    install_k8s_nodes_nerdctl
fi
cp "$ENV_FILE" "$RUN_DIR/effective.env"
printf '\nNODES=%q\n' "$NODES" >> "$RUN_DIR/effective.env"
printf 'WORK_DIR=%q\nLOCAL_PATH=%q\nNFS_PATH=%q\n' "$WORK_DIR" "$LOCAL_PATH" "$NFS_PATH" >> "$RUN_DIR/effective.env"
printf 'PKI_ROOT_CERT=%q\nPKI_ROOT_KEY=%q\n' "$PKI_ROOT_CERT" "$PKI_ROOT_KEY" >> "$RUN_DIR/effective.env"
printf 'COMPONENTS=%q\nIMPORT_IMAGES=%q\nINSTALL_NERDCTL=%q\n' "$COMPONENTS" "$IMPORT_IMAGES" "${INSTALL_NERDCTL:-true}" >> "$RUN_DIR/effective.env"
# 发布前再次完整校验快照；无效快照保留用于诊断，但不能成为可复用索引。
(load_env "$RUN_DIR/effective.env")
log "初始化完成，有效参数: $RUN_DIR/effective.env"

# keys/storage/kernel 单阶段不表示完整初始化完成，不能供 all 跳过初始化。
# worker 扩容的临时配置由扩容回执管理，不登记为用户的常规配置。
if [ "$stage" = all ] && [ "$VALIDATION_SCOPE" = cluster ]; then
    prepared_publish "$ENV_FILE" "$RUN_DIR/effective.env" "$initial_source_sha"
fi
