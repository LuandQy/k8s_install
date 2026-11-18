#!/usr/bin/env bash
component_assert_registry_action() {
    [ "${REGISTRY_MODE:-harbor}" = external-harbor ] || return 0
    case "$1" in
        harbor-install|harbor-projects|images-import)
            die 'external-harbor 只读复用；禁止安装仓库、初始化项目或导入镜像';;
    esac
}
component_validate_public_ca() {
    local ca="$1"
    [ -s "$ca" ] || die '外部 Harbor 公开 CA 文件不存在或为空'
    # Accept certificate bundles, never mixed PEM/private-key files. Validate
    # before copying the public trust material to a run or remote node.
    awk '
      BEGIN {inside=0; count=0; bad=0}
      /^-----BEGIN CERTIFICATE-----\r?$/ {if(inside) bad=1; inside=1; count++; next}
      /^-----END CERTIFICATE-----\r?$/ {if(!inside) bad=1; inside=0; next}
      /^[[:space:]]*$/ {next}
      {if(!inside || $0 !~ /^[A-Za-z0-9+\/=]+\r?$/) bad=1}
      END {exit (bad || inside || count<1)}' "$ca" || die 'HARBOR_CA 必须只包含公开 PEM 证书，不允许私钥或其他内容'
    need openssl
    openssl crl2pkcs7 -nocrl -certfile "$ca" -out /dev/null 2>/dev/null || die 'HARBOR_CA 证书内容无法解析'
}
component_receipt_dir() {
    if [ "${COMPONENTS:-all}" = harbor ]; then printf '%s.harbor.deployment\n' "$STATE_DIR"; else printf '%s.deployment\n' "$STATE_DIR"; fi
}
active_node_lines() {
    local row
    while IFS= read -r row; do
        parse_node "$row"
        case "${COMPONENTS:-all}" in
            all) printf '%s\n' "$row";;
            harbor) if has_role registry; then
                printf '%s|%s|%s|%s|%s|%s|%s|registry|%s|%s|%s|%s|%s\n' "$NODE_NAME" "$NODE_ADDRESS" "$NODE_INTERNAL" "$NODE_USER" "$NODE_PORT" "$NODE_ARCH" "$NODE_OS" "$NODE_CONNECTION" "$NODE_DATA" "$NODE_DATA_MODE" "$NODE_DEVICE" "$NODE_PASS_ENV"
            elif [ "${NTP_MODE:-existing}" = node ] && [ "$NTP_NODE" = "$NODE_NAME" ]; then printf '%s\n' "$row";
            fi;;
            k8s) if has_role control_plane || has_role worker || { [ "$NFS_MODE" = new ] && [ "$NODE_NAME" = "$NFS_NODE" ]; }; then printf '%s\n' "$row"; fi;;
        esac
    done < <(node_lines)
}
component_effective_roles() {
    if [ "${COMPONENTS:-all}" = k8s ]; then printf '%s\n' "$1" | sed -E 's/(^|,)registry(,|$)/\1/g;s/,$//'; else printf '%s\n' "$1"; fi
}
component_marker_namespace() { if [ "${COMPONENTS:-all}" = harbor ]; then printf harbor; else printf cluster; fi; }
component_choose_playbook() {
    case "${COMPONENTS:-all}:${REUSE_HARBOR:-false}" in
        harbor:*) printf playbooks/create_harbor.yaml;;
        k8s:*|all:true) printf playbooks/create_k8s.yaml;;
        *) printf playbooks/create_cluster.yaml;;
    esac
}
component_verify_harbor_state() {
    [ "${REGISTRY_MODE:-harbor}" != external-harbor ] || die 'external-harbor 不能复用或改写受管 Harbor 状态'
    local directory="$STATE_DIR.harbor" expected file
    [ -d "$directory" ] || return 1
    for file in identity.json cluster.env harbor-ca.pem; do
        expected=$(awk -v file="$file" '$2==file {print $1}' "$directory/SHA256SUMS")
        [ -n "$expected" ] && [ "$(sha256_file "$directory/$file")" = "$expected" ] || die 'Harbor 状态摘要不匹配'
    done
    jq -e --arg domain "$HARBOR_DOMAIN" --argjson port "$HARBOR_PORT" '.tool=="kubekey-shell" and .component=="harbor" and .domain==$domain and .port==$port' "$directory/identity.json" >/dev/null || die 'Harbor 地址或端口与保存状态不同'
    if [ "$HARBOR_HTTP" = false ]; then
        [ "$(sha256_file "${HARBOR_CA:-$WORK_DIR/pki/root.crt}")" = "$(sha256_file "$directory/harbor-ca.pem")" ] || die 'Harbor CA 与保存状态不一致'
    fi
}
component_record_harbor() {
    [ "${REGISTRY_MODE:-harbor}" != external-harbor ] || die 'external-harbor 不能记录为受管 Harbor'
    local temporary="$STATE_DIR.harbor.new.$$" ca="${HARBOR_CA:-$WORK_DIR/pki/root.crt}"
    mkdir -p "$temporary"; chmod 700 "$temporary"
    jq --arg domain "$HARBOR_DOMAIN" --argjson port "$HARBOR_PORT" --argjson images_ready "${HARBOR_IMAGES_VERIFIED:-false}" --argjson registries "$(printf '%s\n' "${REGISTRY_NODES[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')" '{tool:"kubekey-shell",schema:1,component:"harbor",domain:$domain,port:$port,images_ready:$images_ready,nodes:map(select(.name as $n | $registries|index($n)!=null)|{name,ip,arch,machine_id,uuid})}' "$RUN_DIR/check/summary.json" > "$temporary/identity.json"
    write_cluster_env "$temporary/cluster.env"
    if [ "$HARBOR_HTTP" = true ]; then printf 'HTTP registry: no TLS CA\n' > "$temporary/harbor-ca.pem"; else cp "$ca" "$temporary/harbor-ca.pem"; fi
    state_checksums "$temporary"
    if [ -e "$STATE_DIR.harbor" ]; then mv "$STATE_DIR.harbor" "$STATE_DIR.harbor.previous.$(date +%s).$$"; fi
    mv "$temporary" "$STATE_DIR.harbor"
}
component_check_existing_report() {
    local row conflict expected actual
    if [ "${REUSE_HARBOR:-false}" = true ]; then
        jq -S '.nodes|sort_by(.name)' "$STATE_DIR.harbor/identity.json" > "$RUN_DIR/registry-saved.json"
        # Saved Harbor-only state may contain only registry nodes, so compare by name.
        jq -S --slurpfile saved "$RUN_DIR/registry-saved.json" '[.[]|select(.name as $n | any($saved[0][];.name==$n))|{name,ip,arch,machine_id,uuid}]|sort_by(.name)' "$RUN_DIR/check/summary.json" > "$RUN_DIR/registry-current.json"
        cmp -s "$RUN_DIR/registry-saved.json" "$RUN_DIR/registry-current.json" || die '复用的 Harbor 节点身份变化'
    fi
    while IFS= read -r row; do
        parse_node "$row"
        while IFS= read -r conflict; do
            case "$conflict" in
                '运行中的服务:docker'|'运行中的服务:harbor'|"仓库端口占用:$HARBOR_PORT") { [ "${REUSE_HARBOR:-false}" = true ] && has_role registry; } || die "$NODE_NAME 未授权的仓库组件";;
                '运行中的服务:containerd') { [ "${REUSE_HARBOR:-false}" = true ] && has_role registry; } || die "$NODE_NAME 已有运行时，需先核实归属";;
                *) die "$NODE_NAME 存在安装冲突: $conflict";;
            esac
        done < <(jq -r --arg name "$NODE_NAME" '.[]|select(.name==$name)|.conflicts[]' "$RUN_DIR/check/summary.json")
    done < <(active_node_lines)
}
component_registry_address() {
    local row address="${HARBOR_VIP:-}"
    [ "${REGISTRY_MODE:-harbor}" != external-harbor ] || address="$HARBOR_ADDRESS"
    if [ -z "$address" ]; then
        while IFS= read -r row; do parse_node "$row"; if has_role registry; then address="$NODE_INTERNAL"; break; fi; done < <(node_lines)
    fi
    ipv4 "$address" || die '无法确定有效的 Harbor IP，请核对 registry 节点/VIP'
    printf '%s\n' "$address"
}
component_preflight_registry() {
    if [ "$COMPONENTS" != k8s ] && [ "${REUSE_HARBOR:-false}" != true ]; then return 0; fi
    [ "$HARBOR_HTTP" = true ] || [ -s "$(jq -r .ca_file "$RUN_DIR/harbor-settings.json")" ] || die '已有 Harbor 需要可信 CA；请配置 HARBOR_CA'
    selected_target_images > "$RUN_DIR/selected-images.json"
    jq --argjson arches "$(json_array "${ARCHES[@]}" | jq -c unique)" '.+{arches:$arches,verify_timeout:0}' "$RUN_DIR/harbor-settings.json" > "$RUN_DIR/preflight-settings.json"
    if [ "$COMPONENTS" = k8s ]; then
        cp "$RUN_DIR/preflight-settings.json" "$RUN_DIR/harbor-settings.json"
        progress_run 'Harbor 认证、镜像标签和架构核验' "$RUN_DIR/harbor-preflight.log" bash "$ROOT/lib/harbor.sh" "$RUN_DIR/preflight-settings.json" --preflight || die '已有 Harbor 未满足安装条件，未启动 KubeKey'
    else
        progress_run '复用 Harbor 健康与认证检查' "$RUN_DIR/harbor-preflight.log" bash "$ROOT/lib/harbor.sh" "$RUN_DIR/harbor-settings.json" --health || die '原 Harbor 不可复用'
    fi
}

# Every current node must match preparation evidence. Extra prepared nodes are
# allowed because Harbor installation intentionally checks only registry nodes.
component_compare_prepared_identity() {
    jq -e --slurpfile prepared "$1" '
      length>0 and all(.[]; . as $current |
        any($prepared[0][]; .name==$current.name and .ip==$current.ip and
          .arch==$current.arch and .machine_id==$current.machine_id and .uuid==$current.uuid))
    ' "$2" >/dev/null || die '节点身份与准备阶段不一致，未执行安装'
}

component_sync_registry_ca() {
    [ "${REGISTRY_MODE:-harbor}" != external-harbor ] || return 0
    [ "${HARBOR_HTTP:-false}" != true ] || return 0
    local ca="${HARBOR_CA:-$WORK_DIR/pki/root.crt}" row
    [ -s "$ca" ] || die '受管 Harbor CA 不存在，无法同步到节点 containerd'
    while IFS= read -r row; do
        parse_node "$row"
        { [ "$NODE_CONNECTION" = local ] || [ "$NODE_CONNECTION" = ssh ]; } || continue
        if has_role control_plane || has_role worker || has_role registry; then
            node_upload "$ca" /etc/kubekey/rise/harbor-ca.pem
            node_run "$ROOT/node_scripts/registry-ca.sh" "$HARBOR_DOMAIN" || die "$NODE_NAME Harbor CA 同步失败"
        fi
    done < <(node_lines)
}
component_update_controller_hosts() {
    local address
    # KubeKey pushes from the controller, so its registry domain must resolve here too.
    address=$(component_registry_address)
    if [ "${REGISTRY_MODE:-harbor}" = external-harbor ]; then
        # External registries are never a controller-hosts mutation request.
        # Verify resolution because controller-side KK/curl may follow auth realms.
        need getent
        local resolved
        resolved=$(getent ahostsv4 "$HARBOR_DOMAIN" | awk '{print $1}' | sort -u) || die '控制端无法解析外部 Harbor 域名；未改写 hosts'
        [ "$resolved" = "$address" ] || die '控制端外部 Harbor 解析与 HARBOR_ADDRESS 不一致；未改写 hosts'
        return 0
    fi
    if awk -v name="$HARBOR_DOMAIN" -v ip="$address" '$0 !~ /# rise-deploy registry$/ {for(i=2;i<=NF;i++) if($i==name && $1!=ip) bad=1} END{exit !bad}' /etc/hosts; then die '控制端 hosts 已有冲突仓库映射'; fi
    cp -a /etc/hosts "/etc/hosts.rise.$(date +%s).bak"
    sed '/# rise-deploy registry$/d' /etc/hosts > "$RUN_DIR/hosts"
    printf '%s %s # rise-deploy registry\n' "$address" "$HARBOR_DOMAIN" >> "$RUN_DIR/hosts"
    cat "$RUN_DIR/hosts" > /etc/hosts
}
