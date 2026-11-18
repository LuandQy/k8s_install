#!/usr/bin/env bash
# Export a strict allowlist. Never pass sourced environment/config files to reports.
ledger_require_runtime() {
    need python3
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 7))' || die '环境台账要求控制端 Python 3.7+（标准库即可），请先离线准备'
}
ledger_build() {
    local row
    ledger_require_runtime
    : > "$RUN_DIR/ledger-nodes.jsonl"
    while IFS= read -r row; do
        parse_node "$row"
        jq -n --arg name "$NODE_NAME" --arg address "$NODE_ADDRESS" --arg internal "$NODE_INTERNAL" \
            --arg user "$NODE_USER" --arg port "$NODE_PORT" --arg arch "$NODE_ARCH" --arg os "$NODE_OS" \
            --arg roles "$NODE_ROLES" --arg mode "$NODE_DATA_MODE" --arg path "$NODE_DATA" --arg device "$NODE_DEVICE" \
            '{name:$name,address:$address,internal_ip:$internal,user:$user,port:$port,arch:$arch,os_package:$os,roles:$roles,storage_mode:$mode,data_path:$path,device:$device}' >> "$RUN_DIR/ledger-nodes.jsonl"
    done < <(node_lines)
    jq -s --arg cluster "$CLUSTER_NAME" --arg version "$KUBE_VERSION" --arg kk "$KK_VERSION" \
        --argjson import_images "$IMPORT_IMAGES" --arg domain "$HARBOR_DOMAIN" --arg port "$HARBOR_PORT" --arg vip "$HARBOR_VIP" --arg scope "$COMPONENTS" \
        --arg registry_mode "$REGISTRY_MODE" --arg registry_address "$(component_registry_address)" \
        --arg endpoint "$ENDPOINT_ADDRESS" --arg endpoint_type "$ENDPOINT_TYPE" --arg pod "$POD_CIDR" --arg svc "$SERVICE_CIDR" \
        --argjson local_storage "$LOCAL_STORAGE" --arg local_path "$LOCAL_PATH" \
        --arg verification_mode "${CLUSTER_VERIFY_MODE:-selected-node}" \
        --arg ntp_mode "$NTP_MODE" --arg ntp_node "$NTP_NODE" --arg ntp_sources "$NTP_SERVERS" \
        --arg nfs_mode "$NFS_MODE" --arg nfs_node "$NFS_NODE" --arg nfs_server "$NFS_SERVER" --arg nfs_path "$NFS_PATH" \
        '{cluster:$cluster,scope:$scope,import_images:$import_images,kubernetes:$version,kubekey:$kk,registry:{mode:$registry_mode,address:$registry_address,domain:$domain,port:$port,vip:$vip},
          network:{endpoint:$endpoint,type:$endpoint_type,pod_cidr:$pod,service_cidr:$svc},storage:{local_enabled:$local_storage,local_path:$local_path},
          verification:{mode:$verification_mode},
          ntp:{mode:$ntp_mode,node:$ntp_node,sources:$ntp_sources},nfs:{mode:$nfs_mode,node:$nfs_node,server:$nfs_server,path:$nfs_path},nodes:.}' \
        "$RUN_DIR/ledger-nodes.jsonl" > "$RUN_DIR/ledger-input.json"
    python3 "$ROOT/lib/ledger.py" "$RUN_DIR/ledger-input.json" "$STATE_DIR" "$WF_FINGERPRINT" "$RUN_DIR"
    # One stable deliverable name for both CLI and Web downloads; the original
    # environment-ledger name remains for compatibility with existing runbooks.
    cp -f "$RUN_DIR/environment-ledger.xlsx" "$RUN_DIR/k8s_harbor_deployment_inventory.xlsx"
    log "台账已生成: $RUN_DIR/k8s_harbor_deployment_inventory.xlsx（兼容 environment-ledger.xlsx；同时生成 JSON、HTML 和 CSV；不含密码）"
}
