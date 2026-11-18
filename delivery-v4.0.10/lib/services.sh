#!/usr/bin/env bash
services_run() {
    local action="$1" row ntp_kind sources clients='' ntp_address='' nfs_server="$NFS_SERVER"
    while IFS= read -r row; do
        parse_node "$row"; clients+="$NODE_INTERNAL "
        if [ "$NTP_MODE" = node ] && [ "$NODE_NAME" = "$NTP_NODE" ]; then ntp_address="$NODE_INTERNAL"; fi
        if [ "$NFS_MODE" = new ] && [ "$NODE_NAME" = "$NFS_NODE" ]; then nfs_server="$NODE_INTERNAL"; fi
    done < <(node_lines)
    # Server first, clients second; read-only verification never rewrites config.
    if [ "$action" = apply ] && [ "$NTP_MODE" = node ]; then
        while IFS= read -r row; do
            parse_node "$row"; [ "$NODE_NAME" = "$NTP_NODE" ] || continue
            node_run "$ROOT/node_scripts/ntp.sh" apply server "$NTP_SERVERS" "$clients" "$NTP_ALLOW_LOCAL" "$NTP_MAX_CORRECTION" "$CLUSTER_NAME" > "$RUN_DIR/$NODE_NAME.ntp-server.log"
        done < <(node_lines)
    fi
    if [ "$COMPONENTS" != harbor ] && [ "$NFS_MODE" = new ]; then
        while IFS= read -r row; do
            parse_node "$row"; [ "$NODE_NAME" = "$NFS_NODE" ] || continue
            node_run "$ROOT/node_scripts/nfs-server.sh" "$NFS_PATH" "$clients $POD_CIDR" "$CLUSTER_NAME" "$NFS_ANON_UID" "$NFS_ANON_GID" "$action" > "$RUN_DIR/$NODE_NAME.nfs-server.log"
        done < <(node_lines)
    fi
    : > "$RUN_DIR/services.jsonl"
    while IFS= read -r row; do
        parse_node "$row"; ntp_kind="$NTP_MODE"; sources="$NTP_SERVERS"
        if [ "$NTP_MODE" = node ]; then
            ntp_kind=client; sources="$ntp_address"
            if [ "$NODE_NAME" = "$NTP_NODE" ]; then ntp_kind=server; sources="$NTP_SERVERS"; fi
        fi
        node_run "$ROOT/node_scripts/ntp.sh" "$action" "$ntp_kind" "$sources" "$clients" "$NTP_ALLOW_LOCAL" "$NTP_MAX_CORRECTION" "$CLUSTER_NAME" > "$RUN_DIR/$NODE_NAME.ntp.log"
        printf 'not_selected\n' > "$RUN_DIR/$NODE_NAME.nfs.log"
        if [ "$NFS_MODE" != none ] && { has_role control_plane || has_role worker; }; then
            node_run "$ROOT/node_scripts/nfs-client.sh" "$nfs_server" "$NFS_PATH" "$NFS_VERSION" > "$RUN_DIR/$NODE_NAME.nfs.log"
        fi
        jq -n --arg node "$NODE_NAME" --arg mode "$ntp_kind" --arg source "$sources" \
            --arg nfs_server "$nfs_server" --arg nfs_path "$NFS_PATH" \
            --rawfile ntp "$RUN_DIR/$NODE_NAME.ntp.log" --rawfile nfs "$RUN_DIR/$NODE_NAME.nfs.log" \
            '{node:$node,ntp:{mode:$mode,sources:$source,evidence:$ntp},nfs:{server:$nfs_server,path:$nfs_path,evidence:$nfs}}' >> "$RUN_DIR/services.jsonl"
    done < <(active_node_lines)
    jq -s '{schema:1,nodes:.}' "$RUN_DIR/services.jsonl" > "$RUN_DIR/services-evidence.json"
}
