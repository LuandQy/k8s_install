#!/usr/bin/env bash
# Add workers only to a cluster recorded by this toolkit.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# 扩容子流程始终保留人工恢复提示，其他入口按各自操作提供建议。
[ "${RECOVERY_CONTEXT:-}" = expansion ] || RECOVERY_CONTEXT=expansion
export RECOVERY_CONTEXT
. "$ROOT/lib/render.sh"
. "$ROOT/lib/artifact.sh"
. "$ROOT/lib/wizard.sh"
. "$ROOT/lib/cluster-state.sh"
. "$ROOT/lib/progress.sh"
. "$ROOT/lib/resume.sh"
. "$ROOT/lib/expansion.sh"
. "$ROOT/lib/workflow.sh"
. "$ROOT/lib/post-verify.sh"
state_dir="$ROOT/state/rise"; nodes_file=''; preview=false; NONINTERACTIVE=false
while [ "$#" -gt 0 ]; do case "$1" in
    --state-dir) state_dir="$2";shift 2;; --nodes) nodes_file="$2";shift 2;;
    --output) RUN_DIR="$2";shift 2;; --preview) preview=true;shift;;
    --skip-post-verify) SKIP_POST_VERIFY=true; export SKIP_POST_VERIFY; shift;;
    -y|--yes) NONINTERACTIVE=true;shift;;
    --help|-h) printf '%s\n' '用法: ./scale-worker.sh --nodes workers.env [--state-dir state/rise] [--preview] [-y]' '只扩容本工具记录的集群，新增清单只允许 worker。--preview 不连接节点。';exit;;
    *) die '扩容参数无效，请使用 --help';;
esac; done
load_managed_state "$state_dir"
[ -n "$nodes_file" ] && [ -f "$nodes_file" ] || die '请通过 --nodes 指定新增 worker 配置'
# A separate subshell prevents a trusted nodes file from accidentally overriding old config.
new_nodes=$(bash -eu -c '. "$1"; printf "%s\n" "${NEW_NODES:?需要 NEW_NODES}"' bash "$nodes_file")
old_nodes="$NODES"
while IFS= read -r line; do
    [ -n "$line" ] || continue; parse_node "$line"
    [ "$NODE_ROLES" = worker ] || die '新增节点仅允许 worker 角色'
done <<< "$new_nodes"
NODES="$old_nodes
$new_nodes"
validate_env
new_run
new_names=(); new_arches=()
while IFS= read -r line; do
    [ -n "$line" ] || continue; parse_node "$line"
    new_names+=("$NODE_NAME"); new_arches+=("$NODE_ARCH")
done <<< "$new_nodes"
[ "${#new_names[@]}" -gt 0 ] || die '新增节点清单为空'
# New-only configuration is consumed by check/init/deps, never by create_cluster.
saved_nodes="$NODES"; NODES="$new_nodes"
write_cluster_env "$RUN_DIR/new-nodes.env"
# 仅运行子配置附带状态路径，保证 init 的未完成操作检查指向同一集群。
# 保持 write_cluster_env 的公共回执格式不变，兼容已有回执比较。
printf 'STATE_DIR=%q\n' "$STATE_DIR" >> "$RUN_DIR/new-nodes.env"
NODES="$saved_nodes"
printf '\nNODES=%q\nVALIDATION_SCOPE=workers\n' "$new_nodes" >> "$RUN_DIR/new-nodes.env"
WORKER_EXPANSION=true
SAVED_HARBOR_CA="$STATE_DIR/harbor-ca.pem"
render_configs
jq -n --argjson names "$(json_array "${new_names[@]}")" '{names:$names}' > "$RUN_DIR/new-names.json"
if [ "$preview" = true ]; then
    log "worker 扩容预览: ${RUN_DIR}；未连接节点或执行安装"; exit
fi
linux_root
[ -n "$ARTIFACT_FILE" ] || die 'worker 扩容目前要求完整离线制品，避免下载改变已有集群版本'
if [ "$NONINTERACTIVE" = true ]; then validate_password
else stage=install; wizard_credentials; fi
controller_lock
assert_no_pending_expansion
expansion_check_receipt
choose_kk
read_cluster_identity > "$RUN_DIR/live-before.json"
jq -e --slurpfile state "$STATE_DIR/identity.json" --arg version "$KUBE_VERSION" \
 '.uid==$state[0].uid and .version==$version and all(.nodes[]; .ready and .version==$version) and (([.nodes[].name]|sort)==([$state[0].nodes[].name]|sort))' "$RUN_DIR/live-before.json" >/dev/null || die '集群 UID、版本、节点清单或健康状态不匹配'
# Verify the offline archive before initializing any new node.
saved_nodes="$NODES"; NODES="$new_nodes"
preflight_artifact
NODES="$saved_nodes"
while IFS= read -r line; do
    [ -n "$line" ] || continue; parse_node "$line"
    jq -e --arg name "$NODE_NAME" --arg ip "$NODE_INTERNAL" 'all(.nodes[]; .name!=$name and (.ips|index($ip)|not))' "$RUN_DIR/live-before.json" >/dev/null || die '新增节点名称或 IP 已在集群中存在'
done <<< "$new_nodes"
# The init subprocess inherits the same controller lock.
stage=init
if [ "$NONINTERACTIVE" = true ]; then
    saved_nodes="$NODES"; NODES="$new_nodes"; silent_preflight; NODES="$saved_nodes"
fi
# init.sh defaults to interactive; -y must also silence the storage/password prompts.
[ "$NONINTERACTIVE" != true ] || export NONINTERACTIVE=true
RUN_DIR="$RUN_DIR/init" bash "$ROOT/init.sh" all --env "$RUN_DIR/new-nodes.env"
check_external_endpoint
# Re-check identity after preparation; old configuration must still match.
read_cluster_identity > "$RUN_DIR/live-after-init.json"
cmp <(jq -S '{uid,version}' "$RUN_DIR/live-before.json") <(jq -S '{uid,version}' "$RUN_DIR/live-after-init.json") || die '初始化期间集群身份发生变化'
# Use initialization's effective new-node paths, keeping all old rows unchanged.
new_nodes=$(bash -eu -c '. "$1"; printf "%s\n" "$NODES"' bash "$RUN_DIR/init/effective.env")
NODES="$old_nodes
$new_nodes"; validate_env
# Artifacts and dependency preparation apply to new workers only.
while IFS= read -r line; do
    parse_node "$line"
    if [ "$NODE_CONNECTION" = local ] && [ "$NODE_DATA_MODE" = native ]; then ALLOW_ROOT_WORKDIR=true; fi
done <<< "$old_nodes"
NODES="$new_nodes"; ARCHES=("${new_arches[@]}")
verify_artifact
prepare_dependencies
stage_tools
while IFS= read -r line; do
    [ -n "$line" ] || continue; parse_node "$line"
    local_path='-'; [ "$LOCAL_STORAGE" != true ] || local_path="$LOCAL_PATH"
    node_run "$ROOT/node_scripts/verify-init.sh" "$NODE_DATA" "$HARBOR_SOURCE_DIR" worker "$local_path" '-' "$NODE_DATA_MODE"
done <<< "$new_nodes"
NODES="$old_nodes
$new_nodes"; validate_env
ca_hash=$(jq -er '.discovery_ca_hash | select(test("^sha256:[0-9a-f]{64}$"))' "$RUN_DIR/live-before.json")
SAVED_HARBOR_CA="$STATE_DIR/harbor-ca.pem"
LIVE_RENDER=true render_configs
# Bind all hosts before changing cluster membership. A pending marker prevents
# reset/redeploy from falling back to an obsolete inventory after interruption.
write_cluster_env "$RUN_DIR/expanded.env"
printf 'STATE_DIR=%q\n' "$STATE_DIR" >> "$RUN_DIR/expanded.env"
RUN_DIR="$RUN_DIR/check" bash "$ROOT/check.sh" --env "$RUN_DIR/expanded.env" --collect-only
expansion_check_identity "$RUN_DIR/check/summary.json"
mkdir "${STATE_DIR}.expansion"
printf '%s\n' "$RUN_DIR" > "${STATE_DIR}.expansion/run"
printf '%s\n' "$RUN_DIR/expanded.env" > "${STATE_DIR}.expansion/expanded-env"
args=(run --workdir "$WORK_DIR" playbooks/add_workers.yaml --project-addr "$ROOT/kk-project" -i "$RUN_DIR/inventory.yaml" -c "$RUN_DIR/config.yaml" -a "$ARTIFACT_FILE")
kk_ssh_preflight "$RUN_DIR/check/summary.json"
progress_run 'KubeKey worker 扩容' "$RUN_DIR/kubekey-add-workers.log" "$KK" "${args[@]}" || die "worker 加入失败，保留日志: $RUN_DIR/kubekey-add-workers.log"
while IFS= read -r line; do
    parse_node "$line"
    if has_role control_plane; then node_run "$ROOT/node_scripts/verify-cluster.sh" > "$RUN_DIR/cluster-nodes.json"; break; fi
done < <(node_lines)
while IFS= read -r line; do
    [ -n "$line" ] || continue; parse_node "$line"
    jq -e --arg name "$NODE_NAME" --arg arch "$NODE_ARCH" --arg version "$KUBE_VERSION" \
        'any(.items[];.metadata.name==$name and .status.nodeInfo.architecture==$arch and .status.nodeInfo.kubeletVersion==$version)' \
        "$RUN_DIR/cluster-nodes.json" >/dev/null || die '新增节点名称、架构或版本验收失败'
done <<< "$new_nodes"
RUN_DIR="$RUN_DIR/check-after" bash "$ROOT/check.sh" --env "$RUN_DIR/expanded.env" --collect-only
cmp <(resume_identity "$RUN_DIR/check/summary.json") <(resume_identity "$RUN_DIR/check-after/summary.json") || die '扩容期间节点身份变化，保留未完成标记'
expansion_save_receipt "$RUN_DIR/check-after/summary.json"
record_cluster_state
mv "${STATE_DIR}.expansion" "$RUN_DIR/expansion-complete"
workflow_sync_and_post_verify "$RUN_DIR/check-after/summary.json"
log "worker 扩容完成: $RUN_DIR"
