#!/usr/bin/env bash
# A completed expansion must also become the plan used by reset/redeploy.
expansion_check_receipt() {
    RECEIPT="${STATE_DIR}.deployment"
    local key
    for key in id status cluster.env inventory.yaml identity.json project.sha256 pki.sha256; do
        [ -s "$RECEIPT/$key" ] || die "扩容缺少原部署记录: $key"
    done
    [ "$(cat "$RECEIPT/status")" = complete ] || die '原部署尚未完成，不能扩容'
    cmp -s "$STATE_DIR/cluster.env" "$RECEIPT/cluster.env" || die '集群状态与部署记录不一致，需先人工核对历史扩容记录'
    [ "$(resume_project_digest)" = "$(cat "$RECEIPT/project.sha256")" ] || die 'KubeKey 项目变化，拒绝扩容'
    DEPLOYMENT_ID=$(cat "$RECEIPT/id")
    for key in HARBOR_CA HARBOR_CERT HARBOR_KEY; do
        [ ! -f "$RECEIPT/$key.path" ] || printf -v "$key" '%s' "$(cat "$RECEIPT/$key.path")"
    done
    resume_pki > "$RUN_DIR/expansion-pki.sha256"
    cmp -s "$RUN_DIR/expansion-pki.sha256" "$RECEIPT/pki.sha256" || die '原证书或私钥变化，拒绝扩容'
}
expansion_check_identity() {
    local baseline="$1"
    jq -S --slurpfile saved "$RECEIPT/identity.json" \
        '[.[] | select(.name as $name | any($saved[0][]; .name==$name)) | {name,ip,arch,machine_id,uuid}] | sort_by(.name)' \
        "$baseline" > "$RUN_DIR/expansion-old-identity.json"
    cmp -s "$RUN_DIR/expansion-old-identity.json" "$RECEIPT/identity.json" || die '扩容前后原节点身份不一致'
    local expected
    expected=$(active_node_lines | cut -d '|' -f1 | jq -Rsc 'split("\n")|map(select(length>0))|sort')
    jq -e --argjson expected "$expected" '([.[].name]|sort)==$expected' "$baseline" >/dev/null || die '扩容后的节点身份采集不完整'
}
expansion_save_receipt() {
    local baseline="$1" old="$RECEIPT" previous="${RECEIPT}.before-expansion-$(date +%Y%m%dT%H%M%S)-$$"
    local replacement="${RECEIPT}.new.$$" managed="$RUN_DIR/managed" row
    expansion_check_identity "$baseline"
    DEPLOYMENT_ID=$(cat "$old/id")
    # Existing ownership must still match; only the newly joined workers get
    # new markers. Never overwrite another deployment's marker.
    while IFS= read -r row; do
        parse_node "$row"
        if jq -e --arg name "$NODE_NAME" 'any(.[]; .name==$name)' "$old/identity.json" >/dev/null; then
            node_run "$ROOT/node_scripts/deployment-marker.sh" verify "$DEPLOYMENT_ID" cluster
        else
            node_run "$ROOT/node_scripts/deployment-marker.sh" create "$DEPLOYMENT_ID" cluster
        fi
    done < <(active_node_lines)
    [ ! -e "$replacement" ] && [ ! -e "$managed" ] || die '扩容状态暂存目录已存在'
    mkdir -p "$managed"; chmod 700 "$managed"
    (
        RUN_DIR="$managed"
        WORKER_EXPANSION=false
        unset SAVED_HARBOR_CA
        REUSE_HARBOR=$(cat "$old/reuse-harbor")
        LIVE_RENDER=true render_configs
        RECEIPT="$replacement"
        resume_save_receipt "$baseline"
        resume_pki > "$RECEIPT/pki.sha256"
        cmp -s "$RECEIPT/pki.sha256" "$old/pki.sha256" || die '扩容期间 PKI 变化'
        printf 'complete\n' > "$RECEIPT/status"
    )
    mv "$old" "$previous"
    mv "$replacement" "$old" || { mv "$previous" "$old"; die '扩容部署记录切换失败'; }
    log "扩容后的完整部署记录已保存；旧记录: $previous"
}
