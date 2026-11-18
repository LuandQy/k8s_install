#!/usr/bin/env bash
json_array() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length>0))'; }
render_configs() {
    local line key connector ssh_password nfs_enabled=false nfs_default=false ca_file
    HOSTS_YAML=''
    local -a targets=()
    while IFS= read -r line; do
        parse_node "$line"
        connector="    $NODE_NAME:
      connector:
        type: $NODE_CONNECTION
        host: $NODE_ADDRESS
        port: $NODE_PORT
        user: $NODE_USER"
        if [ "$NODE_CONNECTION" = ssh ]; then
            if [ "${SSH_AUTH_MODE:-bootstrap}" = password ]; then
                ssh_password=RENDER_ONLY_NO_SECRET
                if [ "${LIVE_RENDER:-false}" = true ]; then
                    [ -n "$NODE_PASS_ENV" ] && [ -n "${!NODE_PASS_ENV:-}" ] || die "缺少 $NODE_NAME 的 SSH 密码环境变量"
                    ssh_password="${!NODE_PASS_ENV}"
                fi
                connector="$connector
        password: $(json_quote "$ssh_password")"
            else connector="$connector
        private_key: $(json_quote "$SSH_KEY")"; fi
        fi
        HOSTS_YAML="$HOSTS_YAML$connector
      internal_ipv4: $NODE_INTERNAL
"
        if has_role registry; then targets+=("$NODE_INTERNAL"); fi
        if [ "$NFS_MODE" = new ] && [ "$NFS_NODE" = "$NODE_NAME" ]; then NFS_SERVER="$NODE_INTERNAL"; fi
    done < <(node_lines)
    if [ "${REGISTRY_MODE:-harbor}" = external-harbor ]; then targets+=("$HARBOR_ADDRESS"); fi
    [ -z "$HARBOR_VIP" ] || targets+=("$HARBOR_VIP")
    CONTROL_PLANES_YAML="$(json_array "${CONTROL_PLANES[@]:-}")"
    WORKERS_YAML="$(json_array "${WORKERS[@]:-}")"
    ETCD_YAML="$(json_array "${ETCD_NODES[@]:-}")"
    REGISTRIES_YAML="$(json_array "${REGISTRY_NODES[@]}")"
    NFS_NODES_YAML="$(json_array "${NFS_NODES[@]:-}")"
    ARCHES_YAML="$(json_array "${ARCHES[@]}" | jq -c unique)"
    
    if [ "$NFS_MODE" != none ]; then nfs_enabled=true; fi
    if [ "$LOCAL_STORAGE" = false ] && [ "$nfs_enabled" = true ]; then nfs_default=true; fi
    if [ "${COMPONENTS:-all}" = harbor ]; then
        CONTROL_PLANES_YAML='[ ]'; WORKERS_YAML='[ ]'; ETCD_YAML='[ ]'; NFS_NODES_YAML='[ ]'; nfs_enabled=false; nfs_default=false
    fi
    NFS_ENABLED="$nfs_enabled"; NFS_DEFAULT="$nfs_default"
    DOWNLOAD_FETCH=true; [ -z "$ARTIFACT_FILE" ] || DOWNLOAD_FETCH=false
    NTP_ENABLED=false; [ -z "$NTP_SERVERS" ] || NTP_ENABLED=true
    NTP_SERVERS_YAML="$(printf '%s' "$NTP_SERVERS" | jq -Rsc 'split(",")|map(select(length>0))')"
    ZONE_YAML="$(json_quote "$ZONE")"; WORK_DIR_YAML="$(json_quote "$WORK_DIR")"
    ENDPOINT_ADDRESS_YAML="$(json_quote "$ENDPOINT_ADDRESS")"; HARBOR_VIP_YAML="$(json_quote "$HARBOR_VIP")"
    HARBOR_VRRP_ID_YAML="$HARBOR_VRRP_ID"
    # BYO root CA: pin KubeKey's policy so a pre-placed root.crt/root.key is
    # validated and reused instead of being regenerated.
    CERTS_POLICY_YAML=''
    [ -z "${PKI_ROOT_CERT:-}" ] || CERTS_POLICY_YAML='  certs:
    ca:
      gen_cert_policy: IfNotPresent'
    KK_ENDPOINT_TYPE="$ENDPOINT_TYPE"
    [ "$ENDPOINT_TYPE" != external ] || KK_ENDPOINT_TYPE=local
    HARBOR_SOURCE_DIR_YAML="$(json_quote "$HARBOR_SOURCE_DIR")"
    LOCAL_PATH_YAML="$(json_quote "$LOCAL_PATH")"; NFS_SERVER_YAML="$(json_quote "$NFS_SERVER")"; NFS_PATH_YAML="$(json_quote "$NFS_PATH")"
    local password=RENDER_ONLY_NO_SECRET
    if [ "${LIVE_RENDER:-false}" = true ] && [ "${COMPONENTS:-all}" != k8s ]; then validate_password; password="$HARBOR_PASSWORD"; fi
    HARBOR_PASSWORD_YAML="$(json_quote "$password")"
    ca_file="$WORK_DIR/pki/root.crt"
    WORKER_FIELDS_YAML=''; WORKER_AUTH_YAML=''
    if [ "${REGISTRY_MODE:-harbor}" = external-harbor ]; then
        WORKER_FIELDS_YAML="    harbor_address: $(json_quote "$HARBOR_ADDRESS")"
    fi
    if [ "${WORKER_EXPANSION:-false}" = true ]; then
        ca_file="${SAVED_HARBOR_CA:-$ca_file}"
        WORKER_AUTH_YAML='      cert_file: ""
      key_file: ""'
        WORKER_FIELDS_YAML="    worker_expansion: true
    new_workers: $(json_array "${new_names[@]}")
    discovery_ca_hash: $(json_quote "${ca_hash:-PREVIEW_ONLY}")
    api_address: $(json_quote "${ENDPOINT_ADDRESS:-$(printf '%s\n' "$NODES" | awk -F '|' '($8 ~ /control_plane/){print $3;exit}')}")
    harbor_address: $(json_quote "$(component_registry_address)")"
    fi
    if [ "${COMPONENTS:-all}" = k8s ]; then WORKER_AUTH_YAML='      cert_file: ""
      key_file: ""'; fi
    EXTERNAL_CERT_YAML='""'; EXTERNAL_KEY_YAML='""'
    if [ -n "$HARBOR_CA" ]; then
        [ "${REGISTRY_MODE:-harbor}" != external-harbor ] || component_validate_public_ca "$HARBOR_CA"
        if [ "${COMPONENTS:-all}" = k8s ] && [ -z "$HARBOR_CERT$HARBOR_KEY" ]; then
            [ -f "$HARBOR_CA" ] || die 'Harbor CA 文件不存在'
            cp "$HARBOR_CA" "$RUN_DIR/harbor-ca.pem"
            ca_file="$RUN_DIR/harbor-ca.pem"
        else
        for key in HARBOR_CA HARBOR_CERT HARBOR_KEY; do [ -f "${!key}" ] || die "证书文件不存在: $key"; done
        cp "$HARBOR_CA" "$RUN_DIR/harbor-ca.pem"; cp "$HARBOR_CERT" "$RUN_DIR/harbor-cert.pem"; cp "$HARBOR_KEY" "$RUN_DIR/harbor-key.pem"
        ca_file="$RUN_DIR/harbor-ca.pem"
        EXTERNAL_CERT_YAML="$(json_quote "$RUN_DIR/harbor-cert.pem")"; EXTERNAL_KEY_YAML="$(json_quote "$RUN_DIR/harbor-key.pem")"
        openssl verify -CAfile "$ca_file" "$RUN_DIR/harbor-cert.pem" >/dev/null
        openssl x509 -in "$RUN_DIR/harbor-cert.pem" -noout -checkhost "$HARBOR_DOMAIN" >/dev/null
        openssl x509 -in "$RUN_DIR/harbor-cert.pem" -pubkey -noout > "$RUN_DIR/cert.pub"
        openssl pkey -in "$RUN_DIR/harbor-key.pem" -passin pass: -pubout > "$RUN_DIR/key.pub"
        cmp -s "$RUN_DIR/cert.pub" "$RUN_DIR/key.pub" || die '证书与私钥不匹配'
        fi
    fi
    CA_FILE_YAML="$(json_quote "$ca_file")"
    PROJECTS_HELPER_YAML="$(json_quote "$ROOT/lib/harbor.sh")"
    PROJECTS_CONFIG_YAML="$(json_quote "$RUN_DIR/harbor-settings.json")"
    SELECTED_IMAGES_YAML="$(json_quote "$RUN_DIR/selected-images.json")"; TOOLS_DIR_YAML="$(json_quote "$RUN_DIR/tools")"
    REGISTRY_INSTALL_TYPE_YAML=harbor; DOWNLOAD_REGISTRY_TYPES_YAML='[harbor]'
    if [ "${REGISTRY_MODE:-harbor}" = external-harbor ]; then REGISTRY_INSTALL_TYPE_YAML='""'; fi
    if [ "${COMPONENTS:-all}" = k8s ]; then DOWNLOAD_REGISTRY_TYPES_YAML='[]'; fi
    [ "${COMPONENTS:-all}" != k8s ] || IMPORT_IMAGES=false
    COMPONENT_FIELDS_YAML=''
    if [ "${COMPONENTS:-all}:${REUSE_HARBOR:-false}:${IMPORT_IMAGES:-true}" != all:false:true ]; then
        COMPONENT_FIELDS_YAML="    components: ${COMPONENTS:-all}
    import_images: ${IMPORT_IMAGES:-true}
"
    fi
    OS_PREPARED=false; [ "${DELIVERY_STEP:-false}" != true ] || OS_PREPARED=true
    SELECTED_MANIFESTS_YAML='[]'
    if [ "${IMAGE_IMPORT_ONLY:-false}" = true ]; then SELECTED_MANIFESTS_YAML=$(selected_target_images | jq -c .); fi
    CALICO_IMAGES_YAML="$(cat "$ROOT/lib/calico-images.json")"
    render_template "$ROOT/inventory-base.yaml" > "$RUN_DIR/inventory.yaml"
    if [ "${WORKER_EXPANSION:-false}" = true ]; then
        printf '    rise_new_workers:\n      hosts: %s\n' "$(json_array "${new_names[@]}")" >> "$RUN_DIR/inventory.yaml"
    fi
    render_template "$ROOT/config-base.yaml" > "$RUN_DIR/config.yaml"
    # jq receives credentials through stdin, never argv.
    {
        json_quote "$password"; json_quote "$HARBOR_DOMAIN"; json_quote "$ca_file"; json_quote "$RUN_DIR/selected-images.json"
        json_array "${targets[@]}"
    } | jq -s --argjson port "$HARBOR_PORT" --argjson plain "$HARBOR_HTTP" \
        '{password:.[0],domain:.[1],ca_file:.[2],selected_file:.[3],targets:.[4],port:$port,plain_http:$plain}' > "$RUN_DIR/harbor-settings.json"
    chmod 600 "$RUN_DIR/inventory.yaml" "$RUN_DIR/config.yaml" "$RUN_DIR/harbor-settings.json"
}
validate_password() {
    [ -n "${HARBOR_PASSWORD:-}" ] || die '请显式设置 HARBOR_PASSWORD 或在向导中输入 Harbor admin 密码；不再提供默认密码'
    [[ "$HARBOR_PASSWORD" =~ ^[A-Za-z0-9.!_@%+=:-]{12,128}$ ]] || die 'HARBOR_PASSWORD 需12-128位，只支持字母、数字及 .!_@%+=:-'
    export HARBOR_PASSWORD
}
