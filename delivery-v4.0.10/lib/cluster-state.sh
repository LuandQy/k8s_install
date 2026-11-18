#!/usr/bin/env bash
# Public cluster parameters only: never serialize shell environment or passwords.
write_cluster_env() {
    local dest="$1" key
    : > "$dest"; chmod 600 "$dest"
    for key in CLUSTER_NAME WORK_DIR SSH_KEY SSH_PARALLEL SSH_AUTH_MODE ZONE KUBE_VERSION KK_VERSION \
        K8S_DOMAIN ENDPOINT_TYPE ENDPOINT_ADDRESS ENDPOINT_PORT POD_CIDR SERVICE_CIDR \
        REGISTRY_MODE HARBOR_DOMAIN HARBOR_PORT HARBOR_HTTP HARBOR_VIP HARBOR_SOURCE_DIR HARBOR_VRRP_ID \
        LOCAL_STORAGE LOCAL_PATH NFS_MODE NFS_NODE NFS_SERVER NFS_PATH NFS_VERSION NFS_ANON_UID NFS_ANON_GID NTP_SERVERS NTP_MODE NTP_NODE NTP_ALLOW_LOCAL NTP_MAX_CORRECTION \
        ARTIFACT_FILE ARTIFACT_SHA256 BOOTSTRAP_ARCHIVE DEPS_MODE MIN_ROOT_FREE_GIB ALLOW_ROOT_WORKDIR NODES; do
        printf '%s=%q\n' "$key" "${!key}" >> "$dest"
    done
    if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
        printf 'SSH_KNOWN_HOSTS=%q\nSSH_KNOWN_HOSTS_SHA256=%q\n' "$SSH_KNOWN_HOSTS" "$(ssh_known_hosts_digest)" >> "$dest"
    fi
    if [ "${REGISTRY_MODE:-harbor}" = external-harbor ]; then
        # Only a public CA path is persisted; no Harbor server/client private key.
        printf 'HARBOR_ADDRESS=%q\nHARBOR_CA=%q\n' "$HARBOR_ADDRESS" "$HARBOR_CA" >> "$dest"
    fi
    [ "${CLUSTER_VERIFY_MODE:-selected-node}" = selected-node ] || printf 'CLUSTER_VERIFY_MODE=%q\n' "$CLUSTER_VERIFY_MODE" >> "$dest"
    [ "${IMPORT_IMAGES:-true}" = true ] || printf 'IMPORT_IMAGES=%q\n' "$IMPORT_IMAGES" >> "$dest"
    [ "${INSTALL_NERDCTL:-true}" = true ] || printf 'INSTALL_NERDCTL=%q\n' "$INSTALL_NERDCTL" >> "$dest"
    [ "${COMPONENTS:-all}" = all ] || printf 'COMPONENTS=%q\n' "$COMPONENTS" >> "$dest"
}
state_checksums() {
    local dir="$1" file
    : > "$dir/SHA256SUMS"
    for file in cluster.env identity.json harbor-ca.pem; do
        printf '%s  %s\n' "$(sha256_file "$dir/$file")" "$file" >> "$dir/SHA256SUMS"
    done
}
load_managed_state() {
    local dir="$1" file expected
    [ -f "$dir/identity.json" ] && [ -f "$dir/SHA256SUMS" ] || die '本工具的集群状态不存在，禁止自动接管已有集群'
    dir=$(cd "$dir" && pwd)
    for file in cluster.env identity.json harbor-ca.pem; do
        expected=$(awk -v file="$file" '$2==file {print $1}' "$dir/SHA256SUMS")
        [ -n "$expected" ] && [ -f "$dir/$file" ] && [ "$(sha256_file "$dir/$file")" = "$expected" ] || die "集群状态摘要不匹配: $file"
    done
    jq -e '.tool=="kubekey-shell" and .schema==1 and (.uid|type=="string" and length>0)' "$dir/identity.json" >/dev/null || die '集群状态来源不支持'
    load_env "$dir/cluster.env"
    STATE_DIR="$dir"
}
read_cluster_identity() {
    local line
    while IFS= read -r line; do
        parse_node "$line"
        if has_role control_plane; then node_run "$ROOT/node_scripts/cluster-identity.sh"; return; fi
    done < <(node_lines)
    die '没有控制平面'
}
record_cluster_state() {
    local temporary ca line
    temporary="${STATE_DIR}.new.$$"
    [ ! -e "$temporary" ] || die '临时状态目录已存在'
    mkdir -p "$temporary"; chmod 700 "$temporary"
    read_cluster_identity > "$temporary/live.json"
    jq --arg tool kubekey-shell '. + {tool:$tool,schema:1}' "$temporary/live.json" > "$temporary/identity.json"
    if [ -f "$STATE_DIR/identity.json" ]; then
        [ "$(jq -r .uid "$STATE_DIR/identity.json")" = "$(jq -r .uid "$temporary/identity.json")" ] || die '集群 UID 变化，拒绝覆盖已有状态'
    fi
    [ "$(jq -r .version "$temporary/identity.json")" = "$KUBE_VERSION" ] || die '实际版本与配置不同，拒绝记录状态'
    write_cluster_env "$temporary/cluster.env"
    ca="${HARBOR_CA:-$WORK_DIR/pki/root.crt}"
    [ -z "${SAVED_HARBOR_CA:-}" ] || ca="$SAVED_HARBOR_CA"
    if [ "$HARBOR_HTTP" = true ]; then printf 'HTTP registry: no TLS CA\n' > "$temporary/harbor-ca.pem"
    else [ -s "$ca" ] || die "Harbor CA 不存在: $ca"; cp "$ca" "$temporary/harbor-ca.pem"; fi
    rm "$temporary/live.json"
    state_checksums "$temporary"
    if [ -e "$STATE_DIR" ]; then mv "$STATE_DIR" "${STATE_DIR}.previous.$(date +%Y%m%dT%H%M%S).$$"; fi
    mv "$temporary" "$STATE_DIR"
    log "集群状态已保存: ${STATE_DIR}（不包含密码）"
}
