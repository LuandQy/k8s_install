#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# 扩容子流程始终保留人工恢复提示，其他入口按各自操作提供建议。
[ "${RECOVERY_CONTEXT:-}" = expansion ] || RECOVERY_CONTEXT=redeploy
export RECOVERY_CONTEXT
. "$ROOT/lib/render.sh"
. "$ROOT/lib/cluster-state.sh"
. "$ROOT/lib/redeploy.sh"
. "$ROOT/lib/prepared-config.sh"
explicit_env=false
env_file="$ROOT/cluster-vars.env"; requested_version=; requested_artifact=; requested_sha=; preview=false; silent=false
while [ "$#" -gt 0 ]; do
 case "$1" in
 --env) env_file="$2"; explicit_env=true; shift 2;;
 --kubernetes) requested_version="$2"; shift 2;;
 --artifact) requested_artifact="$2"; shift 2;;
 --sha256) requested_sha="$2"; shift 2;;
 --output) RUN_DIR="$2"; shift 2;;
 --preview) preview=true; shift;;
 -y|--yes) silent=true; shift;;
 -h|--help) printf '%s\n' '用法: ./deploy.sh redeploy [--kubernetes v1.xx.x] [--artifact 归档] [--sha256 摘要] [--preview] [-y]' '要求先完成 reset --purge-etcd；仅允许改变 K8s 版本和离线包，其余基础参数复用原记录。' '--preview 只生成配置，不连接节点、不核验离线归档内容、不安装。'; exit;;
 *) die '未知 redeploy 参数，请使用 --help';;
 esac
done
load_env "$env_file"
assert_no_pending_expansion
[ "$COMPONENTS" != harbor ] || die 'redeploy 用于 K8s 重建，不用于 Harbor 独立部署'
RECEIPT="${STATE_DIR}.deployment"
redeploy_check_reset
# 核验基础参数前衔接原输入与最新回执，保留初始化和扩容后的实际配置。
load_maintenance_env "$explicit_env"
new_run
redeploy_check_foundation
# The saved deployment defines defaults even if cluster-vars.env still names an older version.
load_env "$RECEIPT/cluster.env"
if [ "$silent" != true ] && [ "$preview" != true ]; then
 NONINTERACTIVE=false
 supported_kubernetes_versions
 prompt "重新部署 Kubernetes 版本 [${requested_version:-$KUBE_VERSION}]: "
 requested_version="${REPLY:-${requested_version:-$KUBE_VERSION}}"
 prompt "离线归档绝对路径 [${requested_artifact:-$ARTIFACT_FILE}]: "
 requested_artifact="${REPLY:-${requested_artifact:-$ARTIFACT_FILE}}"
fi
KUBE_VERSION="${requested_version:-$KUBE_VERSION}"
if [ -n "$requested_artifact" ]; then
 ARTIFACT_FILE="$requested_artifact"
 if [ -n "$requested_sha" ]; then ARTIFACT_SHA256="$requested_sha"
 else [ -f "$ARTIFACT_FILE" ] || die '离线包不存在'; log '计算新归档 SHA256'; ARTIFACT_SHA256=$(sha256_file "$ARTIFACT_FILE"); fi
elif [ -n "$requested_sha" ]; then ARTIFACT_SHA256="$requested_sha"; fi
validate_env
write_cluster_env "$RUN_DIR/redeploy.env"
# 公共回执为兼容历史逐字比较而不保存 STATE_DIR；传给新进程的运行配置必须保存。
# 否则 exec deploy.sh 后会回到默认 state/<集群名>，找不到本次重建的原回执。
printf 'STATE_DIR=%q\n' "$STATE_DIR" >> "$RUN_DIR/redeploy.env"
# Preserve optional external-certificate paths; public state intentionally has no keys/passwords.
for key in HARBOR_CA HARBOR_CERT HARBOR_KEY; do printf '%s=%q\n' "$key" "${!key}" >> "$RUN_DIR/redeploy.env"; done
if [ "$preview" = true ]; then render_configs; log "重新部署预览: ${RUN_DIR}；基础配置保留，未连接节点或安装"; exit; fi
next_env="$RUN_DIR/redeploy.env"
# A password read from the trusted env file is not exported; the child
# redeploy-run re-validates it, so export it before replacing this process.
[ -z "${HARBOR_PASSWORD:-}" ] || validate_password
unset RUN_DIR
args=(redeploy-run --env "$next_env")
[ "$silent" != true ] || args+=(-y)
exec bash "$ROOT/deploy.sh" "${args[@]}"
