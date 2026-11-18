#!/usr/bin/env bash
# Explicit KubeKey reset of a toolkit-managed cluster, preserving Harbor.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# 扩容子流程始终保留人工恢复提示，其他入口按各自操作提供建议。
[ "${RECOVERY_CONTEXT:-}" = expansion ] || RECOVERY_CONTEXT=reset
export RECOVERY_CONTEXT
. "$ROOT/lib/render.sh"
. "$ROOT/lib/cluster-state.sh"
. "$ROOT/lib/resume.sh"
. "$ROOT/lib/progress.sh"
. "$ROOT/lib/prepared-config.sh"
explicit_env=false
env_file="$ROOT/cluster-vars.env"; preview=false; purge=true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env) env_file="$2"; explicit_env=true; shift 2;;
        --output) RUN_DIR="$2"; shift 2;;
        --preview) preview=true; shift;;
        --purge-etcd) purge=true; shift;;
        -y|--yes|--non-interactive) die 'reset 禁止使用 -y；必须查看范围并输入确认串';;
        -h|--help) printf '%s\n' '用法: ./deploy.sh reset [--env 文件] [--purge-etcd] [--preview] [--output 新目录]' '默认删除 K8s、etcd 服务及 etcd 数据，先备份再执行；--purge-etcd 保留为兼容参数。' 'K8s 配置、kubelet/CNI 状态及节点 /etc/kubernetes、/etc/ssl/etcd 会清理。' '保留 Harbor、CRI、PV 数据目录、WORK_DIR/pki、离线包和挂载；保留工作目录 PKI 不代表保留节点证书。' '清理后重新部署使用 redeploy（先 --preview）；不能用 resume 复用旧分步成功记录。'; exit 0;;
        *) die '不支持的 reset 参数，请使用 --help';;
    esac
done
load_env "$env_file"
assert_no_pending_expansion
[ "$COMPONENTS" != harbor ] || die 'reset 只删除 K8s/etcd，不用于 Harbor 独立部署'
RECEIPT="${STATE_DIR}.deployment"
load_maintenance_env "$explicit_env"
for f in id last-run identity.json inventory.yaml; do [ -s "$RECEIPT/$f" ] || die "缺少本工具部署记录 ${f}，禁止接管其他集群"; done
original=$(cat "$RECEIPT/last-run")
[ -f "$original/config.yaml" ] && [ -f "$original/inventory.yaml" ] || die '原始运行配置不完整'
DEPLOYMENT_ID=$(cat "$RECEIPT/id")
new_run
# Render inventory from requested parameters and compare it with the managed one.
render_configs
cmp -s "$RUN_DIR/inventory.yaml" "$RECEIPT/inventory.yaml" || die '当前主机清单与部署记录不符，请使用原配置'
cmp -s "$original/inventory.yaml" "$RECEIPT/inventory.yaml" || die '原始运行主机清单变化'
cp -a "$ROOT/kk-project" "$RUN_DIR/project"
cp "$ROOT/lib/reset-playbook.yaml" "$RUN_DIR/project/playbooks/reset_cluster.yaml"
# Keep the supplement inside the KubeKey execution and log, on every K8s node.
{
    printf '\n- hosts: [k8s_cluster]\n  tasks:\n    - name: Reset | Clean and verify managed Calico network\n      command: |\n'
    printf '        export RISE_RESET_ACTION=cleanup RISE_RESET_POD_CIDR=%q\n' "$POD_CIDR"
    sed 's/^/        /' "$ROOT/node_scripts/reset-network.sh"
} >> "$RUN_DIR/project/playbooks/reset_cluster.yaml"
cp "$original/config.yaml" "$RUN_DIR/reset-config.yaml"
chmod 600 "$RUN_DIR/reset-config.yaml"
args=(run --workdir "$WORK_DIR" playbooks/reset_cluster.yaml --project-addr "$RUN_DIR/project" -i "$original/inventory.yaml" -c "$RUN_DIR/reset-config.yaml" --set delete.etcd=true --set "delete.data=$purge" --set delete.cri=false --set delete.image_registry=false --set delete.dns=false)
preview_kk=tools/amd64/kk; case "$(uname -m)" in aarch64|arm64) preview_kk=tools/arm64/kk;; esac
printf '%q ' "$ROOT/$preview_kk" "${args[@]}" > "$RUN_DIR/command.txt"; printf '\n' >> "$RUN_DIR/command.txt"
printf '集群: %s\n清理: K8s 配置、kubelet/CNI 状态、etcd 服务及节点 /etc/kubernetes、/etc/ssl/etcd\n清空 etcd 数据: %s\n保留: Harbor/镜像、CRI、PV 数据目录、WORK_DIR/pki、离线包、/data 与 fstab（节点证书须另行备份）\n' "$CLUSTER_NAME" "$purge"
printf '节点:\n'; node_lines | awk -F '|' '{printf "  %s %s [%s]\n",$1,$2,$8}'
if [ "$preview" = true ]; then log "删除预览: ${RUN_DIR}；未连接节点或卸载"; exit; fi
linux_root; controller_lock; choose_kk
assert_no_pending_expansion
write_cluster_env "$RUN_DIR/reset.env"
cmp -s "$RUN_DIR/reset.env" "$RECEIPT/cluster.env" || die '当前参数与原部署记录不同，请通过 --env 指定原部署参数文件'
[ "$(resume_project_digest)" = "$(cat "$RECEIPT/project.sha256")" ] || die 'KubeKey 项目变化，请核验后再删除'
# Always collect all node identities before any node is changed.
RUN_DIR="$RUN_DIR/check" bash "$ROOT/check.sh" --env "$ENV_FILE" --collect-only || die '节点采集失败，未执行删除'
resume_identity "$RUN_DIR/check/summary.json" > "$RUN_DIR/node-identity.json"
cmp -s "$RUN_DIR/node-identity.json" "$RECEIPT/identity.json" || die '节点身份与部署记录不同，未执行删除'
resume_marker verify
confirmation="RESET:$CLUSTER_NAME"; [ "$purge" != true ] || confirmation="RESET-AND-PURGE-ETCD:$CLUSTER_NAME"
NONINTERACTIVE=false
prompt "输入 $confirmation 确认删除（其他输入取消）: "
[ "$REPLY" = "$confirmation" ] || die '已取消，未执行卸载'
reset_id="reset-$(date +%Y%m%dT%H%M%S)-$$"
cp -a "$RECEIPT" "$RUN_DIR/deployment-before"
if [ -e "$STATE_DIR" ]; then cp -a "$STATE_DIR" "$RUN_DIR/cluster-state-before"; fi
reset_nodes() {
    local action="$1" line backup
    while IFS= read -r line; do
        parse_node "$line"
        if [ "$NODE_DATA_MODE" = native ]; then backup="/var/backups/rise-reset-backups/$reset_id"; else backup="$NODE_DATA/rise-reset-backups/$reset_id"; fi
        node_run "$ROOT/node_scripts/reset-support.sh" "$action" "$backup" "$DEPLOYMENT_ID" "$NODE_ROLES" "$purge" || return 1
        if [ "$action" = verify ] && [[ ",$NODE_ROLES," = *,control_plane,* || ",$NODE_ROLES," = *,worker,* ]]; then
            node_run "$ROOT/node_scripts/reset-network.sh" verify "$POD_CIDR" || return 1
        fi
    done < <(active_node_lines)
}
reset_nodes backup || die '节点备份未全部完成，未执行 KubeKey 删除'
log "调用 KubeKey 删除，日志: $RUN_DIR/kubekey-reset.log"
restore_needed=true
restore_on_exit() {
    local result=$?
    trap - EXIT
    if [ "$restore_needed" = true ]; then
        reset_nodes restore || printf '[ERROR] 删除中断后的节点标记恢复失败，备份编号: %s\n' "$reset_id" >&2
    fi
    exit "$result"
}
trap restore_on_exit EXIT
status=0
kk_ssh_preflight "$RUN_DIR/check/summary.json"
progress_run 'KubeKey 删除 K8s/etcd' "$RUN_DIR/kubekey-reset.log" "$KK" "${args[@]}" || status=$?
# Even on partial uninstall, restore preparation metadata for diagnostics/retry.
reset_nodes restore || die "节点准备标记或 Harbor 恢复失败，请检查 $RUN_DIR"
restore_needed=false
[ "$status" -eq 0 ] || die "KubeKey 删除失败，保留原状态记录，详见 $RUN_DIR/kubekey-reset.log"
reset_nodes verify || die '卸载验收失败，未标记完成'
if [ -e "$STATE_DIR/identity.json" ]; then mv "$STATE_DIR" "${STATE_DIR}.before-$reset_id"; fi
printf 'reset\n' > "$RECEIPT/status"
printf '%s\n' "$RUN_DIR" > "$RECEIPT/last-reset"
printf '%s\n' "$purge" > "$RECEIPT/etcd-data-cleared"
# The original plan, PKI and ownership stay bound to this deployment.
log "K8s/etcd 删除完成；重新部署请先 ./deploy.sh redeploy --preview；不能用 resume 复用旧分步成功记录；日志与状态备份: $RUN_DIR"
if [ "$purge" != true ]; then log 'etcd 数据已保留；此模式不能用于 etcd 降级或全新集群重建'; fi
