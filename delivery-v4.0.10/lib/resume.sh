#!/usr/bin/env bash
# A receipt binds a retry to the original rendered plan, machines and PKI.
resume_normalize() { jq -Rs --arg run "$2" 'split($run)|join("@RUN@")' < "$1"; }
resume_conflict_allowed() {
    local conflict="$1" roles=",$2," harbor_port="$3" api_port="$4"
    case "$conflict" in
        'Calico路由:'*) [[ "$roles" = *,worker,* || "$roles" = *,control_plane,* ]];;
        '路由与集群CIDR重叠:'*)
            [ "${conflict#*:}" = "${SERVICE_CIDR:-}" ] &&
                [[ "$roles" = *,worker,* || "$roles" = *,control_plane,* ]];;
        '运行中的服务:etcd'|'已有配置或数据:/var/lib/etcd'|'端口占用:2379'|'端口占用:2380') [[ "$roles" = *,etcd,* ]];;
        '运行中的服务:docker'|'运行中的服务:harbor'|"仓库端口占用:$harbor_port") [[ "$roles" = *,registry,* ]];;
        '运行中的服务:containerd') [[ "$roles" = *,registry,* || "$roles" = *,worker,* || "$roles" = *,control_plane,* ]];;
        '已有K8s二进制:kubelet'|'已有K8s二进制:kubeadm'|'运行中的服务:kubelet'|'已有配置或数据:/etc/kubernetes'|'已有配置或数据:/etc/cni/net.d'|'端口占用:10250') [[ "$roles" = *,worker,* || "$roles" = *,control_plane,* ]];;
        '端口占用:6443'|"端口占用:$api_port"|'端口占用:10257'|'端口占用:10259') [[ "$roles" = *,control_plane,* ]];;
        *) return 1;;
    esac
}
resume_identity() { jq -S 'map({name,ip,arch,machine_id,uuid})|sort_by(.name)' "$1"; }
resume_project_digest() {
    (cd "$ROOT/kk-project"; find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(sha256_file "$f")" "$f"; done) | resume_stdin_digest
}
resume_stdin_digest() { if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
resume_pki() {
    [ -d "$WORK_DIR/pki" ] || die '续跑需要保留原 PKI，禁止自动生成替代 CA'
    (cd "$WORK_DIR/pki"; find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(sha256_file "$f")" "$f"; done)
    local key path
    for key in HARBOR_CA HARBOR_CERT HARBOR_KEY; do
        path="${!key:-}"
        [ -z "$path" ] || printf '%s  %s\n' "$(sha256_file "$path")" "$key"
    done
}
resume_marker() {
    local action="$1" line
    while IFS= read -r line; do
        parse_node "$line"
        node_run "$ROOT/node_scripts/deployment-marker.sh" "$action" "$DEPLOYMENT_ID" "$(component_marker_namespace)"
    done < <(active_node_lines)
}
resume_save_receipt() {
    local baseline="$1" cert_variable
    mkdir -p "$RECEIPT"; chmod 700 "$RECEIPT"
    resume_normalize "$RUN_DIR/config.yaml" "$RUN_DIR" > "$RECEIPT/config.json"
    cp "$RUN_DIR/inventory.yaml" "$RECEIPT/inventory.yaml"
    resume_identity "$baseline" > "$RECEIPT/identity.json"
    for cert_variable in HARBOR_CA HARBOR_CERT HARBOR_KEY; do printf '%s\n' "${!cert_variable:-}" > "$RECEIPT/$cert_variable.path"; done
    printf '%s\n' "${COMPONENTS:-all}" > "$RECEIPT/components"
    printf '%s\n' "${IMPORT_IMAGES:-true}" > "$RECEIPT/import-images"
    printf '%s\n' "${REUSE_HARBOR:-false}" > "$RECEIPT/reuse-harbor"
    resume_project_digest > "$RECEIPT/project.sha256"
    printf '%s\n' "$ARTIFACT_SHA256" > "$RECEIPT/artifact.sha256"
    write_cluster_env "$RECEIPT/cluster.env"
    printf '%s\n' "$DEPLOYMENT_ID" > "$RECEIPT/id"
    printf '%s\n' "$RUN_DIR" > "$RECEIPT/last-run"
    printf 'running\n' > "$RECEIPT/status"
}
resume_check_plan() {
    local file resume_status
    [ "${COMPONENTS:-all}" = "$(cat "$RECEIPT/components" 2>/dev/null || printf all)" ] || die '续跑不能更换部署范围'
    [ "${IMPORT_IMAGES:-true}" = "$(cat "$RECEIPT/import-images" 2>/dev/null || printf true)" ] || die '续跑不能更换镜像导入策略'
    # A missing, unreadable or unknown status is not proof of an unfinished
    # deployment: only running/interrupted receipts may be resumed. A reset
    # cluster must go through redeploy, never resume.
    resume_status="$(cat "$RECEIPT/status" 2>/dev/null || true)"
    case "$resume_status" in
        running|interrupted) ;;
        complete) die '该部署已完成，请使用 verify 或 add-workers';;
        reset) die '集群已 reset，请使用 ./deploy.sh redeploy；不能 resume';;
        *) die '部署状态记录缺失、不可读或无法识别；请由管理员核对原回执，不能自动续跑';;
    esac
    resume_normalize "$RUN_DIR/config.yaml" "$RUN_DIR" > "$RUN_DIR/resume-config.json"
    cmp -s "$RUN_DIR/resume-config.json" "$RECEIPT/config.json" || die '部署配置（含凭据）发生变化，拒绝续跑'
    cmp -s "$RUN_DIR/inventory.yaml" "$RECEIPT/inventory.yaml" || die '主机清单变化，拒绝续跑'
    write_cluster_env "$RUN_DIR/resume.env"
    cmp -s "$RUN_DIR/resume.env" "$RECEIPT/cluster.env" || die '现场参数变化，拒绝续跑'
    [ "$(resume_project_digest)" = "$(cat "$RECEIPT/project.sha256")" ] || die 'KubeKey 项目文件变化，拒绝续跑'
    [ "$ARTIFACT_SHA256" = "$(cat "$RECEIPT/artifact.sha256")" ] || die '离线包摘要变化，拒绝续跑'
    DEPLOYMENT_ID=$(cat "$RECEIPT/id")
    resume_marker verify
    [ -s "$RECEIPT/pki.sha256" ] || die '原部署没有可核验的 PKI 记录，需人工处理'
    resume_pki > "$RUN_DIR/resume-pki.sha256"
    cmp -s "$RUN_DIR/resume-pki.sha256" "$RECEIPT/pki.sha256" || die '证书或私钥变化，拒绝续跑'
}
resume_check_report() {
    local line conflict
    resume_identity "$RUN_DIR/check/summary.json" > "$RUN_DIR/resume-identity.json"
    cmp -s "$RUN_DIR/resume-identity.json" "$RECEIPT/identity.json" || die '节点身份变化，拒绝续跑'
    while IFS= read -r line; do
        parse_node "$line"
        while IFS= read -r conflict; do
            if [[ "$conflict" = Calico路由:* ]]; then
                node_run "$ROOT/node_scripts/deployment-marker.sh" verify "$DEPLOYMENT_ID" "$(component_marker_namespace)" || die "$NODE_NAME 路由归属无法核验，拒绝续跑"
            fi
            if [ "$conflict" = "路由与集群CIDR重叠:$SERVICE_CIDR" ]; then
                node_run "$ROOT/node_scripts/deployment-marker.sh" verify "$DEPLOYMENT_ID" "$(component_marker_namespace)" || die "$NODE_NAME Service 路由部署归属不符"
                node_run "$ROOT/node_scripts/verify-service-route.sh" "$SERVICE_CIDR" "$DEPLOYMENT_ID" || die "$NODE_NAME Service 路由没有匹配的归属记录，拒绝续跑"
            fi
            resume_conflict_allowed "$conflict" "$NODE_ROLES" "$HARBOR_PORT" "$ENDPOINT_PORT" || die "$NODE_NAME 存在续跑不允许的冲突: $conflict"
            log "$NODE_NAME 本次部署已有组件: $conflict"
        done < <(jq -r --arg name "$NODE_NAME" '.[]|select(.name==$name)|.conflicts[]' "$RUN_DIR/check/summary.json")
    done < <(active_node_lines)
}
resume_capture_exit() {
    local result=$?
    trap - EXIT
    if [ -d "$WORK_DIR/pki" ]; then resume_pki > "$RECEIPT/pki.sha256.tmp" && mv "$RECEIPT/pki.sha256.tmp" "$RECEIPT/pki.sha256"; fi
    if [ "$(cat "$RECEIPT/status")" != complete ]; then printf 'interrupted\n' > "$RECEIPT/status"; fi
    exit "$result"
}
# Legacy import is intentionally limited to the diagnosed CA-path failure.
resume_import_legacy() {
    local original="$1"
    [ ! -e "$RECEIPT" ] || die '已有部署记录，不能导入历史运行'
    original=$(cd "$original" && pwd)
    [ "$original" != "$RUN_DIR" ] || die '不能导入当前运行'
    for f in config.yaml inventory.yaml check/summary.json kubekey.log; do [ -s "$original/$f" ] || die "历史记录不完整: $f"; done
    jq -e 'length>0 and all(.[]; .conflicts==[])' "$original/check/summary.json" >/dev/null || die '历史运行没有干净环境基线'
    grep -Fq 'Harbor | Synchronize self signed ca cert to remote host' "$original/kubekey.log" || die '不支持自动导入该历史失败'
    grep -Fq "stat $WORK_DIR/pki/root.crt: no such file or directory" "$original/kubekey.log" || die '历史失败类型不匹配'
    resume_normalize "$original/config.yaml" "$original" > "$RUN_DIR/legacy-config.json"
    resume_normalize "$RUN_DIR/config.yaml" "$RUN_DIR" > "$RUN_DIR/resume-config.json"
    cmp -s "$RUN_DIR/legacy-config.json" "$RUN_DIR/resume-config.json" || die '历史配置与当前配置不一致'
    cmp -s "$original/inventory.yaml" "$RUN_DIR/inventory.yaml" || die '历史主机清单与当前不一致'
    [ -s "$ROOT/kubekey/pki/root.crt" ] || die '原始 PKI 不存在，禁止导入'
    for f in "$ROOT/kubekey/pki/"*; do [ ! -f "$f" ] || cmp -s "$f" "$WORK_DIR/pki/$(basename "$f")" || die '保留证书与原始 PKI 不一致'; done
    openssl verify -CAfile "$WORK_DIR/pki/root.crt" "$WORK_DIR/pki/image_registry.crt" >/dev/null
    # Identity and conflict validation happens before creating node ownership markers.
    RECEIPT="${STATE_DIR}.deployment"
    resume_save_receipt "$original/check/summary.json"
    if ! (resume_check_report); then rm -rf "$RECEIPT"; die '历史节点核验失败，未创建节点标记'; fi
    resume_pki > "$RECEIPT/pki.sha256"
    cp "$original/kubekey.log" "$RECEIPT/legacy-kubekey.log"
    resume_marker create
    log "已核验并导入历史部署: $original"
}
