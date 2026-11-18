#!/usr/bin/env bash
redeploy_check_reset() {
    [ "$(cat "$RECEIPT/status" 2>/dev/null)" = reset ] || die '需先完成 ./deploy.sh reset --purge-etcd，不能覆盖现有集群'
    [ "$(cat "$RECEIPT/etcd-data-cleared" 2>/dev/null)" = true ] || die 'etcd 数据未清空，请先执行 ./deploy.sh reset --purge-etcd'
}
redeploy_check_foundation() {
    write_cluster_env "$RUN_DIR/redeploy-current.env"
    grep -Ev '^(KUBE_VERSION|ARTIFACT_FILE|ARTIFACT_SHA256|COMPONENTS)=' "$RUN_DIR/redeploy-current.env" > "$RUN_DIR/current-foundation.env"
    grep -Ev '^(KUBE_VERSION|ARTIFACT_FILE|ARTIFACT_SHA256|COMPONENTS)=' "$RECEIPT/cluster.env" > "$RUN_DIR/saved-foundation.env"
    cmp -s "$RUN_DIR/current-foundation.env" "$RUN_DIR/saved-foundation.env" || die '基础配置已变化；仅允许更换 K8s 版本和离线包，请使用原部署参数'
}
redeploy_check_plan() {
    local original
    redeploy_check_reset
    redeploy_check_foundation
    original=$(cat "$RECEIPT/last-run")
    cmp -s "$RUN_DIR/inventory.yaml" "$RECEIPT/inventory.yaml" || die '节点角色或连接配置变化'
    [ "$(resume_project_digest)" = "$(cat "$RECEIPT/project.sha256")" ] || die 'KubeKey 项目发生变化，拒绝重新部署'
    resume_pki > "$RUN_DIR/redeploy-pki.sha256"
    cmp -s "$RUN_DIR/redeploy-pki.sha256" "$RECEIPT/pki.sha256" || die '原证书或私钥变化'
    # Only the selected Kubernetes version and per-run helper paths may differ.
    resume_normalize "$RUN_DIR/config.yaml" "$RUN_DIR" | sed -E 's/(kube_version: )[a-zA-Z0-9.]+/\1@VERSION@/g;s/(kube_version: \[)[a-zA-Z0-9.]+/\1@VERSION@/g' > "$RUN_DIR/new-plan.json"
    cp "$RECEIPT/config.json" "$RUN_DIR/old-plan.json"
    sed -E 's/(kube_version: )[a-zA-Z0-9.]+/\1@VERSION@/g;s/(kube_version: \[)[a-zA-Z0-9.]+/\1@VERSION@/g' "$RUN_DIR/old-plan.json" > "$RUN_DIR/old-plan-normalized.json"
    cmp -s "$RUN_DIR/new-plan.json" "$RUN_DIR/old-plan-normalized.json" || die '渲染配置或 Harbor 凭据发生变化，拒绝重新部署'
    DEPLOYMENT_ID=$(cat "$RECEIPT/id")
    resume_marker verify
}
redeploy_check_report() {
    local line conflict
    resume_identity "$RUN_DIR/check/summary.json" > "$RUN_DIR/redeploy-identity.json"
    cmp -s "$RUN_DIR/redeploy-identity.json" "$RECEIPT/identity.json" || die '节点身份变化'
    while IFS= read -r line; do
        parse_node "$line"
        while IFS= read -r conflict; do
            case "$conflict" in
                '运行中的服务:docker'|'运行中的服务:harbor'|"仓库端口占用:$HARBOR_PORT") has_role registry || die "$NODE_NAME 存在非仓库角色的仓库组件";;
                '运行中的服务:containerd') has_role registry || has_role worker || has_role control_plane || die '非预期运行时';;
                *) die "$NODE_NAME 重置不完整或存在冲突: $conflict";;
            esac
        done < <(jq -r --arg name "$NODE_NAME" '.[]|select(.name==$name)|.conflicts[]' "$RUN_DIR/check/summary.json")
        node_run "$ROOT/node_scripts/redeploy-check.sh" "$NODE_ROLES"
    done < <(node_lines)
}
redeploy_new_receipt() {
    local old="$RECEIPT" previous="${RECEIPT}.before-redeploy-$(date +%Y%m%dT%H%M%S)-$$"
    # A reset followed by redeploy starts a new deployment. Stage records from
    # the previous install must not be reused as succeeded - they would skip
    # k8s-install after the cluster was reset - but keep them for audit.
    if [ -e "${STATE_DIR}.workflow" ]; then
        mv "${STATE_DIR}.workflow" "${STATE_DIR}.workflow.before-redeploy-$(date +%Y%m%dT%H%M%S)-$$"
    fi
    RECEIPT="${old}.new.$$"
    resume_save_receipt "$RUN_DIR/check/summary.json"
    resume_pki > "$RECEIPT/pki.sha256"
    printf '%s\n' "$previous" > "$RECEIPT/previous-deployment"
    mv "$old" "$previous"
    mv "$RECEIPT" "$old" || { mv "$previous" "$old"; die '新部署记录切换失败'; }
    RECEIPT="$old"
    log "旧部署记录归档: $previous"
}
