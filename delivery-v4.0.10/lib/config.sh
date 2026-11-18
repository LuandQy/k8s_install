#!/usr/bin/env bash
# Trusted env loading, defaults and validation; source via common.sh.
# No menu, credential prompt or node execution is performed by this module.
load_env() {
    local forced_noninteractive="${NONINTERACTIVE:-false}"
    ENV_FILE="${1:-$ROOT/cluster-vars.env}"
    [ -f "$ENV_FILE" ] || die "请先复制 cluster-vars.env.example 为 cluster-vars.env 并填写现场参数"
    ENV_FILE="$(cd -- "$(dirname -- "$ENV_FILE")" && pwd)/$(basename -- "$ENV_FILE")"
    # This is explicitly a trusted shell configuration, not an untrusted dotenv parser.
    . "$ENV_FILE"
    : "${COMPONENTS:=all}" "${IMPORT_IMAGES:=true}"
    [ -z "${CLI_COMPONENTS:-}" ] || COMPONENTS="$CLI_COMPONENTS"
    [ -z "${CLI_IMPORT_IMAGES:-}" ] || IMPORT_IMAGES="$CLI_IMPORT_IMAGES"
    case "$COMPONENTS" in all|harbor|k8s) ;; *) die 'COMPONENTS 必须为 all/harbor/k8s';; esac
    [[ "$IMPORT_IMAGES" = true || "$IMPORT_IMAGES" = false ]] || die 'IMPORT_IMAGES 必须为 true/false'
    [ "$forced_noninteractive" != true ] || NONINTERACTIVE=true
    local default_kube_version
    default_kube_version="$(default_kubernetes_version)" || die '无法从 configs/v*.yaml 发现 Kubernetes 版本'
    : "${KUBE_VERSION:=$default_kube_version}" "${KK_VERSION:=v4.0.10}" "${WORK_DIR:=/data/rise-deploy}"
    : "${PACKAGE_WORK_DIR:=/data/kubekey-package}" "${SSH_KEY:=/root/.ssh/rise_deploy}" "${ZONE:=cn}"
    : "${K8S_DOMAIN:=lb.rise.io}" "${ENDPOINT_TYPE:=$(schema_default ENDPOINT_TYPE)}" "${ENDPOINT_ADDRESS:=$(schema_default ENDPOINT_ADDRESS)}"
    : "${POD_CIDR:=10.233.64.0/18}" "${SERVICE_CIDR:=10.233.0.0/18}"
    : "${REGISTRY_MODE:=harbor}" "${HARBOR_DOMAIN:=harbor.rise.io}" "${HARBOR_PORT:=443}" "${HARBOR_HTTP:=false}" "${HARBOR_VRRP_ID:=31}"
    : "${HARBOR_SOURCE_DIR:=/var/lib/harbor/data}" "${HARBOR_VIP:=}" "${HARBOR_PASSWORD:=}"
    : "${HARBOR_CA:=}" "${HARBOR_CERT:=}" "${HARBOR_KEY:=}"
    : "${PKI_ROOT_CERT:=}" "${PKI_ROOT_KEY:=}"
    : "${HARBOR_ADDRESS:=}" "${CLUSTER_VERIFY_MODE:=$(schema_default CLUSTER_VERIFY_MODE)}"
    : "${LOCAL_STORAGE:=$(schema_default LOCAL_STORAGE)}" "${LOCAL_PATH:=/data/local-pv}" "${NFS_MODE:=$(schema_default NFS_MODE)}" "${NFS_NODE:=}" "${NFS_SERVER:=}" "${NFS_PATH:=/data/nfs}"
    : "${ARTIFACT_FILE:=}" "${ARTIFACT_SHA256:=}" "${BOOTSTRAP_ARCHIVE:=}" "${DEPS_MODE:=iso}" "${NTP_SERVERS:=}" "${SSH_PARALLEL:=5}" "${NONINTERACTIVE:=false}"
    : "${CLUSTER_NAME:=rise}" "${STATE_DIR:=$ROOT/state/$CLUSTER_NAME}" "${VALIDATION_SCOPE:=cluster}"
    : "${MIN_ROOT_FREE_GIB:=20}" "${ALLOW_ROOT_WORKDIR:=false}"
    : "${ENDPOINT_PORT:=6443}"
    : "${SSH_AUTH_MODE:=bootstrap}" "${NTP_MODE:=$(schema_default NTP_MODE)}" "${NTP_NODE:=}" "${NTP_ALLOW_LOCAL:=$(schema_default NTP_ALLOW_LOCAL)}"
    : "${SSH_KNOWN_HOSTS:=}" "${SSH_KNOWN_HOSTS_SHA256:=}"
    : "${NTP_MAX_CORRECTION:=0.5}" "${NFS_VERSION:=4}" "${NFS_ANON_UID:=65534}" "${NFS_ANON_GID:=65534}"
    need jq
    validate_env
    nfs_notice
    if [ "$COMPONENTS" != all ]; then
        ARCHES=()
        while IFS= read -r active; do parse_node "$active"; ARCHES+=("$NODE_ARCH"); done < <(active_node_lines)
    fi
}
validate_env() {
    supported_kubernetes_versions | grep -Fxq -- "$KUBE_VERSION" || die "Kubernetes 版本不在 configs/v*.yaml 支持范围: $KUBE_VERSION"
    case "$KK_VERSION" in v4.0.9|v4.0.10) ;; *) die "KubeKey 版本必须为 v4.0.9 或 v4.0.10，当前为 $KK_VERSION";; esac
    [[ "$HARBOR_VRRP_ID" =~ ^[0-9]{1,3}$ ]] && [ "$HARBOR_VRRP_ID" -ge 1 ] && [ "$HARBOR_VRRP_ID" -le 255 ] ||
        die 'HARBOR_VRRP_ID 必须为 1-255 的整数（仅 ha-harbor 使用）'
    [ "$REGISTRY_MODE" = ha-harbor ] || [ "$HARBOR_VRRP_ID" = 31 ] || log_warn 'HARBOR_VRRP_ID 只用于 ha-harbor；当前仓库模式会忽略该值'
    case "$ENDPOINT_TYPE" in local|kube-vip|external) ;; *) die 'ENDPOINT_TYPE 无效';; esac
    case "$REGISTRY_MODE" in harbor|ha-harbor|external-harbor) ;; *) die 'REGISTRY_MODE 无效';; esac
    case "${CLUSTER_VERIFY_MODE:-selected-node}" in selected-node|cross-node) ;; *) die 'CLUSTER_VERIFY_MODE 必须为 selected-node/cross-node';; esac
    if [ "$REGISTRY_MODE" = external-harbor ]; then
        [ "$COMPONENTS" = k8s ] || die 'external-harbor 仅支持 COMPONENTS=k8s；不安装或管理外部仓库'
        ipv4 "$HARBOR_ADDRESS" || die 'external-harbor 需要有效 HARBOR_ADDRESS IPv4'
        number=$(ip_number "$HARBOR_ADDRESS")
        [ "$number" -ge 16777216 ] && [ "$number" -lt 3758096384 ] &&
            { [ "$number" -lt 2130706432 ] || [ "$number" -gt 2147483647 ]; } &&
            { [ "$number" -lt 2851995648 ] || [ "$number" -gt 2852061183 ]; } || die '外部 Harbor 地址不能为回环、未指定、链路本地或组播地址'
        [ "$HARBOR_HTTP" = false ] && [ -n "$HARBOR_CA" ] || die 'external-harbor 需要 HTTPS 和公开 HARBOR_CA'
        [ -z "$HARBOR_CERT$HARBOR_KEY$HARBOR_VIP" ] || die 'external-harbor 不接收服务器证书/私钥或受管 VIP'
        [ "$HARBOR_DOMAIN" != "$K8S_DOMAIN" ] || die '外部 Harbor 与 API 域名不能相同'
    else
        [ -z "$HARBOR_ADDRESS" ] || die 'HARBOR_ADDRESS 仅用于 external-harbor 模式'
    fi
    if [ -n "${PKI_ROOT_CERT}${PKI_ROOT_KEY}" ]; then
        [ -n "$PKI_ROOT_CERT" ] && [ -n "$PKI_ROOT_KEY" ] ||
            die '自带根 CA 需要同时填写 PKI_ROOT_CERT 和 PKI_ROOT_KEY'
        safe_path "$PKI_ROOT_CERT"; safe_path "$PKI_ROOT_KEY"
        [ "$PKI_ROOT_CERT" != "$PKI_ROOT_KEY" ] || die 'PKI_ROOT_CERT 与 PKI_ROOT_KEY 不能相同'
    fi
    case "$DEPS_MODE" in preinstalled|iso|bootstrap|online) ;; *) die 'DEPS_MODE 无效';; esac
    case "${SSH_AUTH_MODE:-bootstrap}" in bootstrap|key|password) ;; *) die 'SSH_AUTH_MODE 无效';; esac
    if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
        safe_path "$SSH_KNOWN_HOSTS"
        if [ -n "${SSH_KNOWN_HOSTS_SHA256:-}" ]; then
            [[ "$SSH_KNOWN_HOSTS_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'SSH_KNOWN_HOSTS_SHA256 无效'
            ssh_known_hosts_digest >/dev/null
        fi
    else
        [ -z "${SSH_KNOWN_HOSTS_SHA256:-}" ] || die 'SSH_KNOWN_HOSTS_SHA256 需要 SSH_KNOWN_HOSTS'
    fi
    case "${NTP_MODE:-existing}" in existing|external|node) ;; *) die 'NTP_MODE 无效';; esac
    [[ "${NTP_ALLOW_LOCAL:-false}" = true || "${NTP_ALLOW_LOCAL:-false}" = false ]] || die 'NTP_ALLOW_LOCAL 无效'
    [[ "${NTP_MAX_CORRECTION:-0.5}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'NTP_MAX_CORRECTION 无效'
    awk -v n="${NTP_MAX_CORRECTION:-0.5}" 'BEGIN {exit !(n>0)}' || die 'NTP_MAX_CORRECTION 必须大于零'
    [[ "${NFS_VERSION:-4}" = 4 || "${NFS_VERSION:-4}" = 3 ]] || die 'NFS_VERSION 只支持 3/4'
    [[ "${NFS_ANON_UID:-65534}" =~ ^[0-9]{1,9}$ && "${NFS_ANON_GID:-65534}" =~ ^[0-9]{1,9}$ ]] || die 'NFS UID/GID 无效'
    local source
    # Declare first: read -a on an empty line leaves an undeclared array unset,
    # which breaks the expansion below under "set -u" on older Bash.
    local -a sources=()
    IFS=, read -r -a sources <<< "${NTP_SERVERS:-}"
    for source in "${sources[@]}"; do [[ "$source" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'NTP_SERVERS 必须是逗号分隔的 IP/域名'; done
    [ "${NTP_MODE:-existing}" != external ] || [ -n "${NTP_SERVERS:-}" ] || die 'external NTP 需要 NTP_SERVERS'
    case "$NFS_MODE" in none|new|existing) ;; *) die 'NFS_MODE 无效';; esac
    case "$LOCAL_STORAGE:$HARBOR_HTTP:$NONINTERACTIVE" in *[!a-z:]* ) die '布尔配置无效';; esac
    local val line role names=' ' addresses=' ' locals=0 first last lo hi number
    for val in "$LOCAL_STORAGE" "$HARBOR_HTTP" "$NONINTERACTIVE"; do [[ "$val" = true || "$val" = false ]] || die '布尔字段只能是 true/false'; done
    for val in "$K8S_DOMAIN" "$HARBOR_DOMAIN"; do [[ "$val" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die '域名格式无效'; done
    [[ "$HARBOR_PORT" =~ ^[0-9]+$ && "$ENDPOINT_PORT" =~ ^[0-9]+$ && "$SSH_PARALLEL" =~ ^[0-9]+$ ]] || die '端口或并发数无效'
    [ "$HARBOR_PORT" -ge 1 ] && [ "$HARBOR_PORT" -le 65535 ] && [ "$ENDPOINT_PORT" -ge 1 ] && [ "$ENDPOINT_PORT" -le 65535 ] || die '端口越界'
    [ "$SSH_PARALLEL" -ge 1 ] && [ "$SSH_PARALLEL" -le 32 ] || die '并发数必须为 1-32'
    [[ "$CLUSTER_NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die 'CLUSTER_NAME 无效'
    case "$VALIDATION_SCOPE" in cluster|workers) ;; *) die '校验范围无效';; esac
    [[ "$MIN_ROOT_FREE_GIB" =~ ^[1-9][0-9]{0,4}$ ]] || die 'MIN_ROOT_FREE_GIB 必须为1-99999的整数'
    [[ "$ALLOW_ROOT_WORKDIR" = true || "$ALLOW_ROOT_WORKDIR" = false ]] || die 'ALLOW_ROOT_WORKDIR 必须为 true/false'
    [ -z "$ENDPOINT_ADDRESS" ] || ipv4 "$ENDPOINT_ADDRESS" || die 'ENDPOINT_ADDRESS 无效'
    [ "$ENDPOINT_TYPE" != kube-vip ] || [ -n "$ENDPOINT_ADDRESS" ] || die 'kube-vip 需要 ENDPOINT_ADDRESS'
    [ "$ENDPOINT_TYPE" != external ] || [ -n "$ENDPOINT_ADDRESS" ] || die 'external 需要 ENDPOINT_ADDRESS'
    for val in "$WORK_DIR" "$PACKAGE_WORK_DIR" "$HARBOR_SOURCE_DIR" "$LOCAL_PATH" "$NFS_PATH"; do safe_path "$val"; done
    [ -z "$BOOTSTRAP_ARCHIVE" ] || safe_path "$BOOTSTRAP_ARCHIVE"
    WORK_DIR="${WORK_DIR%/}"; HARBOR_SOURCE_DIR="${HARBOR_SOURCE_DIR%/}"
    case "$HARBOR_SOURCE_DIR" in /var/lib/docker|/var/lib/containerd|/var/lib/kubelet) die 'Harbor 源目录与其他组件冲突';; esac
    read -r first last <<< "$(cidr_bounds "$POD_CIDR")"
    read -r lo hi <<< "$(cidr_bounds "$SERVICE_CIDR")"
    [ "$first" -gt "$hi" ] || [ "$lo" -gt "$last" ] || die 'Pod 与 Service CIDR 重叠'
    CONTROL_PLANES=(); WORKERS=(); ETCD_NODES=(); REGISTRY_NODES=(); NFS_NODES=(); ARCHES=()
    local normalized_nodes=''
    [ -n "${NODES:-}" ] || die '节点清单为空'
    while IFS= read -r line; do
        parse_node "$line"
        [[ "$NODE_NAME" =~ ^[a-z][a-z0-9-]*$ && "$names" != *" $NODE_NAME "* ]] || die '节点名称无效或重复'
        names="$names$NODE_NAME "
        ipv4 "$NODE_ADDRESS" && ipv4 "$NODE_INTERNAL" || die '节点 IPv4 无效'
        [[ "$addresses" != *" $NODE_INTERNAL "* ]] || die '内部 IP 重复'
        addresses="$addresses$NODE_INTERNAL "
        for val in "$NODE_ADDRESS" "$NODE_INTERNAL"; do
            number="$(ip_number "$val")"
            { [ "$number" -lt "$first" ] || [ "$number" -gt "$last" ]; } && { [ "$number" -lt "$lo" ] || [ "$number" -gt "$hi" ]; } || die '节点地址与集群 CIDR 冲突'
            [ "$REGISTRY_MODE" != external-harbor ] || [ "$number" -ne "$(ip_number "$HARBOR_ADDRESS")" ] || die '外部 Harbor 不能同时列为受管节点'
        done
        [[ "$NODE_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$NODE_PORT" =~ ^[0-9]+$ ]] || die 'SSH 用户或端口无效'
        [ "$NODE_PORT" -ge 1 ] && [ "$NODE_PORT" -le 65535 ] || die 'SSH 端口越界'
        case "$NODE_ARCH" in amd64|arm64) ;; *) die '节点架构无效';; esac
        case "$NODE_OS" in ubuntu-24.04-debs|ubuntu-22.04-debs|kylin-v10SP3-2403-rpms) ;; *) die 'OS 依赖包无效';; esac
        case "$NODE_CONNECTION" in local) locals=$((locals+1));; ssh) ;; *) die '连接方式无效';; esac
        [ "$locals" -le 1 ] || die '仅允许一个 local 节点'
        safe_path "$NODE_DATA"
        case "$NODE_DATA_MODE" in auto|format|existing|native) ;; *) die '数据盘模式无效';; esac
        [[ -z "$NODE_DEVICE" || "$NODE_DEVICE" =~ ^/dev/[a-zA-Z0-9_./-]+$ ]] || die '设备路径无效'
        [[ -z "$NODE_PASS_ENV" || "$NODE_PASS_ENV" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die '密码变量名无效'
        IFS=, read -r -a role_list <<< "$NODE_ROLES"
        for role in "${role_list[@]}"; do case "$role" in control_plane|worker|etcd|registry|nfs|ntp) ;; *) die '角色无效';; esac; done
        if [ "$VALIDATION_SCOPE" = workers ]; then
            [ "$NODE_ROLES" = worker ] || die '新增节点仅允许 worker 角色'
        else
            if has_role control_plane && ! has_role etcd; then NODE_ROLES="$NODE_ROLES,etcd"; fi
            if has_role etcd && ! has_role control_plane; then die 'etcd 必须与 master 同机'; fi
        fi
        normalized_nodes="$normalized_nodes$NODE_NAME|$NODE_ADDRESS|$NODE_INTERNAL|$NODE_USER|$NODE_PORT|$NODE_ARCH|$NODE_OS|$NODE_ROLES|$NODE_CONNECTION|$NODE_DATA|$NODE_DATA_MODE|$NODE_DEVICE|$NODE_PASS_ENV
"
        has_role control_plane && CONTROL_PLANES+=("$NODE_NAME")
        has_role worker && WORKERS+=("$NODE_NAME")
        has_role etcd && ETCD_NODES+=("$NODE_NAME")
        has_role registry && REGISTRY_NODES+=("$NODE_NAME")
        ARCHES+=("$NODE_ARCH")
    done < <(node_lines)
    NODES="$normalized_nodes"
    # Self-hosted NTP/NFS defaults deliberately select the first control plane.
    # Explicit node names are never invented when an operator supplied a topology.
    if [ "${NTP_MODE:-existing}" = node ] && [ -z "${NTP_NODE:-}" ] && [ "${#CONTROL_PLANES[@]}" -gt 0 ]; then
        NTP_NODE="${CONTROL_PLANES[0]}"
    fi
    if [ "${NFS_MODE:-none}" = new ] && [ -z "${NFS_NODE:-}" ] && [ "${#CONTROL_PLANES[@]}" -gt 0 ]; then
        NFS_NODE="${CONTROL_PLANES[0]}"
    fi
    if [ "${CLUSTER_VERIFY_MODE:-selected-node}" = cross-node ]; then
        [ "$(printf '%s\n' "${ARCHES[@]}" | sort -u | wc -l)" -eq 1 ] || die 'cross-node 暂不支持混合架构'
    fi
    [ "$VALIDATION_SCOPE" != workers ] || return 0
    if [ "$COMPONENTS" != harbor ]; then
    case "${#CONTROL_PLANES[@]}" in 1|3) ;; *) die 'master 数量只允许 1 或 3';; esac
    [ "${#CONTROL_PLANES[@]}" -eq "${#ETCD_NODES[@]}" ] || die 'etcd 必须与 master 一一对应'
    [ "${#CONTROL_PLANES[@]}" -ne 3 ] || [ "$ENDPOINT_TYPE" != local ] || die '三 master 必须使用 kube-vip 或 external'
    [ "$ENDPOINT_TYPE" != kube-vip ] || [[ "$addresses" != *" $ENDPOINT_ADDRESS "* ]] || die 'API VIP 与节点地址冲突'
    fi
    if [ "$REGISTRY_MODE" = external-harbor ]; then
        [ "${#REGISTRY_NODES[@]}" -eq 0 ] || die 'external-harbor 不能声明 registry 节点；外部仓库不进入 inventory'
        number=$(ip_number "$HARBOR_ADDRESS")
        { [ "$number" -lt "$first" ] || [ "$number" -gt "$last" ]; } && { [ "$number" -lt "$lo" ] || [ "$number" -gt "$hi" ]; } || die '外部 Harbor 地址与集群 CIDR 冲突'
        [ -z "$ENDPOINT_ADDRESS" ] || [ "$HARBOR_ADDRESS" != "$ENDPOINT_ADDRESS" ] || die '外部 Harbor 与 API 入口地址不能相同'
    elif [ "$REGISTRY_MODE" = ha-harbor ]; then
        [ "${#REGISTRY_NODES[@]}" -ge 2 ] && ipv4 "$HARBOR_VIP" || die 'HA Harbor 需要两台仓库节点和 VIP'
        [[ "$addresses" != *" $HARBOR_VIP "* ]] || die 'Harbor VIP 与节点 IP 冲突'
        [ -z "$ENDPOINT_ADDRESS" ] || [ "$HARBOR_VIP" != "$ENDPOINT_ADDRESS" ] || die 'Harbor VIP 与 API 入口不能相同'
    else
        [ "${#REGISTRY_NODES[@]}" -eq 1 ] && [ -z "$HARBOR_VIP" ] || die 'Harbor 模式只允许一台仓库节点且不能配置 VIP'
    fi
    if [ "${NTP_MODE:-existing}" = node ]; then
        [[ "$names" = *" $NTP_NODE "* && -n "$NTP_NODE" ]] || die 'NTP_NODE 不存在'
        [ -n "$NTP_SERVERS" ] || [ "$NTP_ALLOW_LOCAL" = true ] || die '离线本地时间源必须显式设置 NTP_ALLOW_LOCAL=true'
    fi
    if [ "$NFS_MODE" = new ]; then [[ "$names" = *" $NFS_NODE "* ]] || die 'NFS_NODE 不存在'; NFS_NODES=("$NFS_NODE"); fi
    [ "$NFS_MODE" != existing ] || [[ "$NFS_SERVER" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die '需要有效 NFS_SERVER'
    if [ "$REGISTRY_MODE" != external-harbor ] && [ -n "$HARBOR_CERT$HARBOR_KEY" ]; then
        log_warn '受管 Harbor 的服务证书由 KubeKey 生成并校验 SAN；HARBOR_CERT/HARBOR_KEY 不会改变 Harbor 实际证书。需要自带 CA 时请预置 WORK_DIR/pki/root.crt 与 root.key，再让 KubeKey 以此签发'
    fi
    if [ "$COMPONENTS" = k8s ] && [ -n "$HARBOR_CA" ] && [ -z "$HARBOR_CERT$HARBOR_KEY" ]; then
        [ "$HARBOR_HTTP" = false ] || die 'HTTP 仓库不能设置 CA'
    elif [ -n "$HARBOR_CA$HARBOR_CERT$HARBOR_KEY" ]; then
        [ -n "$HARBOR_CA" ] && [ -n "$HARBOR_CERT" ] && [ -n "$HARBOR_KEY" ] && [ "$HARBOR_HTTP" = false ] || die '外部 TLS 需同时提供 CA、证书和密钥'
    fi
}
