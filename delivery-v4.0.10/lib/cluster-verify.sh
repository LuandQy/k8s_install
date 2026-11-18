#!/usr/bin/env bash
# Execute from one control-plane node; optional probes cover all Kubernetes nodes.
cluster_verify() {
    local row selected='' remote rc=0 ca base="$RUN_DIR/cluster-verify-input.json"
    jq -n '{schema:1,status:"failed",phase:"controller-preflight",error:"Controller prerequisite did not complete; see stage error log",resources_retained:false,cleanup:{status:"not_started"}}' > "$RUN_DIR/cluster-verify-evidence.json"
    need python3
    while IFS= read -r row; do
        parse_node "$row"
        if has_role control_plane; then selected="$row"; break; fi
    done < <(node_lines)
    [ -n "$selected" ] || die 'cluster-verify 需要一个已配置的控制平面'
    ca="${HARBOR_CA:-$WORK_DIR/pki/root.crt}"
    [ -s "$ca" ] || die 'cluster-verify 缺少公开 Harbor CA'
    [ "$HARBOR_HTTP" = false ] || die 'cluster-verify 的严格 TLS 验收不支持 HTTP Harbor'
    parse_node "$selected"
    node_lines | jq -Rn '[inputs|split("|")|{name:.[0],ip:.[2],arch:.[5],roles:(.[7]|split(",")),data_path:.[9],data_mode:.[10]}]' > "$RUN_DIR/cluster-verify-nodes.json"
    jq -n --slurpfile nodes "$RUN_DIR/cluster-verify-nodes.json" \
        --arg cluster "$CLUSTER_NAME" --arg version "$KUBE_VERSION" --arg api "$K8S_DOMAIN" \
        --arg api_ip "${ENDPOINT_ADDRESS:-$NODE_INTERNAL}" --argjson api_port "$ENDPOINT_PORT" \
        --arg harbor "$HARBOR_DOMAIN" --arg harbor_ip "$(component_registry_address)" --argjson harbor_port "$HARBOR_PORT" \
        --argjson storage "$LOCAL_STORAGE" --arg local_path "$LOCAL_PATH" \
        --arg verification_mode "${CLUSTER_VERIFY_MODE:-selected-node}" \
        --arg fingerprint "$(cat "$WF_DIR/fingerprint")" \
        '{schema:1,cluster:$cluster,version:$version,nodes:$nodes[0],api:{host:$api,port:$api_port,ip:$api_ip},harbor:{host:$harbor,port:$harbor_port,ip:$harbor_ip},storage:{enabled:$storage,path:$local_path},verification:{mode:$verification_mode},fingerprint:$fingerprint}' > "$base"
    # Receipt checks and image selection finish before any node or cluster mutation.
    python3 "$ROOT/lib/cluster_verify.py" config --base "$base" \
        --registry-receipt "$WF_DIR/images-verify.json" --node-receipt "$WF_DIR/node-images-verify.json" \
        --identity-dir "$STATE_DIR" --ca "$ca" --output "$RUN_DIR/cluster-verify-config.json" || {
        die 'cluster-verify 前置证据不完整；诊断镜像须已离线导入并通过该节点架构的 CRI 验收'; }
    parse_node "$selected"
    cat > "$RUN_DIR/cluster-verify-allocate.sh" <<'EOF'
set -eu
[ "$(id -u)" = 0 ]
command -v python3 >/dev/null
umask 077
mktemp -d /var/tmp/rise-cluster-verify.XXXXXXXX
EOF
    remote=$(node_run "$RUN_DIR/cluster-verify-allocate.sh") || die '无法准备功能验收节点工作目录'
    [[ "$remote" =~ ^/var/tmp/rise-cluster-verify\.[a-zA-Z0-9]{8}$ ]] || die '功能验收返回了不安全的工作目录'
    printf '%s\n' "$remote" > "$RUN_DIR/cluster-verify-remote-dir"
    node_upload "$ROOT/lib/cluster_verify.py" "$remote/cluster_verify.py"
    node_upload "$RUN_DIR/cluster-verify-config.json" "$remote/config.json"
    node_upload "$ca" "$remote/harbor-ca.pem"
    cat > "$RUN_DIR/cluster-verify-execute.sh" <<'EOF'
set -eu
cd "$1"
printf '%s  cluster_verify.py\n%s  config.json\n%s  harbor-ca.pem\n' "$2" "$3" "$4" | sha256sum -c - >&2
exec python3 ./cluster_verify.py run --config ./config.json --output-dir "$1"
EOF
    log "功能验收模式=${CLUSTER_VERIFY_MODE:-selected-node}；PVC 与内核 I/O 监测仅覆盖 ${NODE_NAME}，HA 不在本阶段范围。节点证据: $remote"
    node_run "$RUN_DIR/cluster-verify-execute.sh" "$remote" \
        "$(sha256_file "$ROOT/lib/cluster_verify.py")" "$(sha256_file "$RUN_DIR/cluster-verify-config.json")" "$(sha256_file "$ca")" \
        > "$RUN_DIR/cluster-verify-return.json" 2> "$RUN_DIR/cluster-verify-node.log" || rc=$?
    if jq -e '.schema==1 and (.status=="passed" or .status=="failed")' "$RUN_DIR/cluster-verify-return.json" >/dev/null 2>&1; then
        mv "$RUN_DIR/cluster-verify-return.json" "$RUN_DIR/cluster-verify-evidence.json"
    else
        jq -n --arg node "$NODE_NAME" --arg path "$remote" --argjson code "$rc" \
            '{schema:1,status:"failed",phase:"node-execution",error:"Node did not return complete evidence; inspect remote evidence and node log",exit_code:$code,node:$node,resources_retained:true,remote_evidence_dir:$path,cleanup:{status:"unknown"}}' > "$RUN_DIR/cluster-verify-evidence.json"
        [ "$rc" -ne 0 ] || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        if declare -F progress_error_summary >/dev/null; then progress_error_summary "$RUN_DIR/cluster-verify-node.log"; fi
        jq -r '"[cluster-verify ERROR] phase="+(.phase//"unknown")+" "+(.error//"node execution failed")' "$RUN_DIR/cluster-verify-evidence.json" >&2
        log "功能验收停止，保留本次资源和证据；节点=$NODE_NAME 目录=$remote 日志=$RUN_DIR/cluster-verify-node.log"
        return "$rc"
    fi
    jq -e '.status=="passed" and .cleanup.status=="passed" and .cleanup.namespace_absent==true and .io_guard.status=="passed"' \
        "$RUN_DIR/cluster-verify-evidence.json" >/dev/null || die '功能验收未返回完整成功证据'
}
