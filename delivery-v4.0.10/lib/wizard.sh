#!/usr/bin/env bash
# 交互输入从终端读取；密码隐藏输入并仅在当前进程中传递，不写入生成的配置。
ask_default() {
    local label="$1" default="$2"
    prompt "$label [$default]: "
    REPLY="${REPLY:-$default}"
}
ask_secret() {
    local name="$1" label="$2" secret=''
    [ "${NONINTERACTIVE:-false}" != true ] || die '静默模式不能读取密码'
    printf '%s' "$label" > /dev/tty
    IFS= read -r -s secret < /dev/tty || die '未能读取密码'
    printf '\n' > /dev/tty
    if [ -n "$secret" ]; then printf -v "$name" '%s' "$secret"; export "$name"; fi
}
recommended_ip() {
    local address=''
    if command -v ip >/dev/null 2>&1; then
        address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1);exit}}')
        [ -n "$address" ] || address=$(ip -o -4 addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth)/ {split($4,a,"/");print a[1];exit}')
    fi
    printf '%s' "${address:-127.0.0.1}"
}
recommended_artifact() {
    local candidate
    for candidate in "$ROOT/artifact/kubekey-artifact.tgz" "$ROOT/kubekey/artifact/kubekey-artifact.tgz"; do
        if [ -f "$candidate" ]; then printf '%s' "$candidate"; return; fi
    done
}
# 校验失败只重问当前字段。返回值保存在 REPLY，避免命令替换丢失交互状态。
ask_valid() {
    local label="$1" default="$2" kind="$3" valid
    while :; do
        ask_default "$label" "$default"
        valid=false
        case "$kind" in
            ipv4) if ipv4 "$REPLY"; then valid=true; fi;;
            name) [[ "$REPLY" =~ ^[a-z][a-z0-9-]*$ ]] && valid=true;;
            user) [[ "$REPLY" =~ ^[a-z_][a-z0-9_-]*$ ]] && valid=true;;
            port) if [[ "$REPLY" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$REPLY))" -ge 1 ] && [ "$((10#$REPLY))" -le 65535 ]; then REPLY="$((10#$REPLY))"; valid=true; fi;;
            number) [[ "$REPLY" =~ ^[1-9][0-9]{0,3}$ ]] && valid=true;;
            path) if (safe_path "$REPLY") 2>/dev/null; then valid=true; fi;;
            domain) [[ "$REPLY" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] && valid=true;;
            file) [ -f "$REPLY" ] && valid=true;;
            version) if supported_kubernetes_versions | grep -Fxq -- "$REPLY"; then valid=true; fi;;
            *) case "|$kind|" in *"|$REPLY|"*) [ -n "$REPLY" ] && valid=true;; esac;;
        esac
        [ "$valid" != true ] || return 0
        printf '输入无效，请重新填写当前项：%s。\n' "$label" >&2
    done
}
. "$ROOT/lib/wizard-nodes.sh"

# 仅接受一个独立的字面量赋值：普通字符、转义字符和单/双/ANSI-C 引号。
# 不试图解释任意 Bash 程序。复合命令、命令替换、参数展开等请先人工拆成
# 模板风格的一行一个变量。拒绝时保留原文件，避免删除同一行的其他逻辑。
wizard_literal_assignment() {
    local expression
    IFS= read -r expression <<'REGEX'
^[[:blank:]]*[a-zA-Z_][a-zA-Z0-9_]*=([^[:space:]\'";&|()<>$`]+|'[^']*'|"([^"\\$`]|\\.)*"|\$'([^'\\]|\\.)*'|\\.)*[[:blank:]]*(#.*)?$
REGEX
    [[ "$1" =~ $expression ]]
}
# 语法检查出现诊断时继续读；单个行尾反斜杠也需要继续读，
# 避免把下一物理行误当成新赋值。here-document 在写入入口单独拒绝。
wizard_block_complete() {
    local block="$1" diagnostics tail slashes=0
    diagnostics=$(bash -n <<< "$block" 2>&1) || return 1
    [ -z "$diagnostics" ] || return 1
    tail="$block"
    while [[ "$tail" = *\\ ]]; do tail="${tail%?}"; slashes=$((slashes+1)); done
    [ "$((slashes%2))" -eq 0 ]
}
# 使用完整语法块读取文件，防止把自定义多行字符串内部的“KEY=...”当成赋值。
# bash -n 只检查语法，不执行配置。原文件直到全部处理成功才原子替换。
wizard_set() {
    local file="$1" key="$2" value="$3" line block found=false temp assignment
    # 不同 Bash 版本对未闭合 here-document 的 -n 返回值不同，无法可靠分块。
    # 保守拒绝包含 << 的手写配置（含注释/字符串），请改用模板的字面量赋值。
    # 正常生成的节点清单不含此语法；拒绝发生在创建临时文件之前。
    if grep -q '<<' "$file"; then
        die '配置含 here-document 或 << 文本，不能安全自动编辑；请按模板整理独立赋值，原文件未修改'
    fi
    temp=$(mktemp "${file}.XXXXXX")
    while IFS= read -r line || [ -n "$line" ]; do
        block="$line"
        while ! wizard_block_complete "$block"; do
            IFS= read -r line || { rm -f "$temp"; die '配置语法块未闭合，原文件未修改'; }
            block="$block"$'\n'"$line"
        done
        assignment="^[[:blank:]]*${key}="
        if [[ "$block" =~ $assignment ]]; then
            wizard_literal_assignment "$block" || {
                rm -f "$temp"
                die "$key 不是可安全编辑的独立赋值；请按模板拆成一行一个变量后重试，原文件未修改"
            }
            if [ "$found" = false ]; then printf '%s=%q\n' "$key" "$value"; found=true; fi
        else printf '%s\n' "$block"; fi
    done < "$file" > "$temp"
    [ "$found" = true ] || printf '%s=%q\n' "$key" "$value" >> "$temp"
    chmod 600 "$temp"; mv "$temp" "$file"
}
# Editing and replacing drafts share a lifecycle boundary. A workflow can have
# changed SSH/storage before a component receipt exists. Load the original
# trusted configuration before calling this guard.
wizard_assert_editable() {
    local record
    for record in "$STATE_DIR/identity.json" "${STATE_DIR}.workflow" \
        "${STATE_DIR}.deployment" "${STATE_DIR}.harbor.deployment" \
        "${STATE_DIR}.expansion" "${STATE_DIR}.harbor"; do
        if [ -e "$record" ] || [ -L "$record" ]; then
            die '已有工作流、部署或维护记录，请保留原配置并使用维护或恢复；普通配置编辑和重新填写不能改写已绑定配置'
        fi
    done
}
wizard_setup() {
    local target="$1" temp endpoint endpoint_address endpoint_port registry_mode registry_vip
    local cluster_name ssh_mode ssh_key ntp_mode ntp_node ntp_sources ntp_local nfs_mode nfs_node nfs_server nfs_path version domain harbor_domain artifact line masters registries choice
    if [ -f "$target" ]; then
        ask_valid '发现已有配置：1 复用；2 按项修改；3 重新填写（保留备份）' 1 '1|2|3'
        case "$REPLY" in 1) return 0;; 2) wizard_edit "$target"; return;; esac
        # Reuse above stays read-only. Check replacement before making a draft.
        (load_env "$target"; wizard_assert_editable) || return $?
    fi
    ask_valid '集群名称（默认状态目录按此命名，部署后不要改名）' "${CLUSTER_NAME:-rise}" name
    cluster_name="$REPLY"
    WIZARD_NODES=''
    while :; do
        wizard_nodes
        masters=0; registries=0
        while IFS= read -r line; do
            parse_node "$line"
            if has_role control_plane; then masters=$((masters+1)); fi
            if has_role registry; then registries=$((registries+1)); fi
        done <<< "$WIZARD_NODES"
        endpoint=local; endpoint_address=''; endpoint_port=6443
        if [ "${CLI_COMPONENTS:-all}" != harbor ]; then
            choice=1; [ "$masters" -lt 3 ] || choice=2
            if [ "$masters" -ge 3 ]; then
                ask_valid 'API 入口：2 kube-vip 虚拟 IP；3 已有外部负载均衡；4 haproxy 内置代理（免 VIP）' "$choice" '2|3|4'
            else ask_valid 'API 入口：1 单控制平面本机；2 kube-vip；3 外部负载均衡；4 haproxy 内置代理' "$choice" '1|2|3|4'; fi
            case "$REPLY" in 1) endpoint=local;; 2) endpoint=kube-vip;; 3) endpoint=external;; 4) endpoint=haproxy;; esac
            if [ "$endpoint" = kube-vip ] || [ "$endpoint" = external ]; then
                ask_valid 'API VIP / 外部负载均衡 IP' '' ipv4; endpoint_address="$REPLY"
                ask_valid 'API 入口端口' 6443 port; endpoint_port="$REPLY"
            fi
        fi
        registry_mode=harbor; registry_vip=''
        if [ "$registries" -ge 2 ]; then
            registry_mode=ha-harbor
            ask_valid '多个仓库节点：请输入 Harbor 独立 VIP' '' ipv4; registry_vip="$REPLY"
        elif [ "$registries" -ne 1 ]; then
            printf '需要一个仓库节点，HA 仓库需至少两个；请修改节点角色。\n'; continue
        fi
        nfs_mode=new; nfs_node=''; nfs_server=''; nfs_path=/data/nfs
        if [ "${CLI_COMPONENTS:-all}" != harbor ]; then
            ask_valid 'NFS：1 不使用；2 使用清单内节点提供服务；3 使用已有外部服务' 2 '1|2|3'
            case "$REPLY" in
                2) nfs_mode=new; NFS_MODE=new nfs_notice
                   ask_valid 'NFS 服务端节点名（deps 从离线包安装依赖）' "$(printf '%s\n' "$WIZARD_NODES" | head -n 1 | cut -d'|' -f1)" name; nfs_node="$REPLY";;
                3) nfs_mode=existing; NFS_MODE=existing nfs_notice
                   ask_valid '已有 NFS 服务端 IP 或域名' '' domain; nfs_server="$REPLY";;
            esac
            if [ "$nfs_mode" != none ]; then ask_valid 'NFS 导出目录' /data/nfs path; nfs_path="$REPLY"; fi
        fi
        printf 'SSH 认证仅用于 ssh 节点；local 使用将来运行 CLI 的本机。普通 SSH 用户仍须支持免密 sudo。\n'
        ask_valid 'SSH 认证：1 配置控制端到节点免密（必要时用密码）；2 仅用已有密钥；3 持续密码登录' 1 '1|2|3'
        case "$REPLY" in 1) ssh_mode=bootstrap;; 2) ssh_mode=key;; 3) ssh_mode=password;; esac
        ssh_key="${SSH_KEY:-/root/.ssh/rise_deploy}"
        if [ "$ssh_mode" != password ]; then
            ask_valid '执行控制端 SSH 私钥路径（接入阶段再检查存在性与冲突）' "$ssh_key" path
            ssh_key="$REPLY"
        fi
        ntp_mode=node; ntp_node=''; ntp_sources=''; ntp_local=true
        ask_valid 'NTP：1 保留并验收现场 chrony；2 指定外部时间源；3 指定集群节点为时间源' 3 '1|2|3'
        case "$REPLY" in
            2) ntp_mode=external; ask_valid '时间源 IP/域名（多个可在配置中编辑）' '' domain; ntp_sources="$REPLY";;
            3) ntp_mode=node
               ask_valid 'NTP 服务端节点名' "$(printf '%s\n' "$WIZARD_NODES" | head -n 1 | cut -d'|' -f1)" name; ntp_node="$REPLY"
               ask_valid '时间基准：1 指定上游；2 完全离线，明确允许本地时钟（不保证真实时间准确）' 2 '1|2'
               if [ "$REPLY" = 2 ]; then ntp_local=true
               else ask_valid '上游时间源 IP/域名' '' domain; ntp_sources="$REPLY"; fi;;
        esac
        version="$(default_kubernetes_version)"; domain=lb.rise.io; harbor_domain=harbor.rise.io
        if [ "${CLI_COMPONENTS:-all}" = harbor ]; then
            printf '推荐 Harbor 域名：%s\n' "$harbor_domain"
        else
            printf '推荐版本：%s；API 域名：%s；Harbor 域名：%s\n' "$version" "$domain" "$harbor_domain"
        fi
        ask_valid '1 使用推荐版本/域名；2 修改' 1 '1|2'
        if [ "$REPLY" = 2 ]; then
            if [ "${CLI_COMPONENTS:-all}" != harbor ]; then
                printf '离线包支持版本：%s\n' "$(supported_kubernetes_versions | paste -sd ' ' -)"
                ask_valid 'Kubernetes 版本' "$version" version; version="$REPLY"
                ask_valid 'Kubernetes 域名' "$domain" domain; domain="$REPLY"
            fi
            ask_valid 'Harbor 域名' "$harbor_domain" domain; harbor_domain="$REPLY"
        fi
        artifact=$(recommended_artifact)
        ask_valid '离线归档路径（必须是已有文件）' "$artifact" file; artifact="$REPLY"
        artifact="$(cd -- "$(dirname -- "$artifact")" && pwd)/$(basename -- "$artifact")"
        # 在临时文件中生成并整体校验，失败不覆盖用户配置。原文件备份仅在最终提交时创建。
        umask 077; temp=$(mktemp "${target}.XXXXXX")
        cp "$ROOT/cluster-vars.env.example" "$temp"
        wizard_set "$temp" CLUSTER_NAME "$cluster_name"
        wizard_set "$temp" COMPONENTS "${CLI_COMPONENTS:-all}"
        wizard_set "$temp" NODES "$WIZARD_NODES"
        wizard_set "$temp" SSH_AUTH_MODE "$ssh_mode"; wizard_set "$temp" SSH_KEY "$ssh_key"
        wizard_set "$temp" NTP_MODE "$ntp_mode"
        wizard_set "$temp" NTP_NODE "$ntp_node"; wizard_set "$temp" NTP_SERVERS "$ntp_sources"
        wizard_set "$temp" NTP_ALLOW_LOCAL "$ntp_local"
        wizard_set "$temp" ENDPOINT_TYPE "$endpoint"; wizard_set "$temp" ENDPOINT_ADDRESS "$endpoint_address"
        wizard_set "$temp" ENDPOINT_PORT "$endpoint_port"; wizard_set "$temp" REGISTRY_MODE "$registry_mode"
        wizard_set "$temp" HARBOR_VIP "$registry_vip"; wizard_set "$temp" NFS_MODE "$nfs_mode"
        wizard_set "$temp" NFS_NODE "$nfs_node"; wizard_set "$temp" NFS_SERVER "$nfs_server"
        wizard_set "$temp" NFS_PATH "$nfs_path"; wizard_set "$temp" KUBE_VERSION "$version"
        wizard_set "$temp" K8S_DOMAIN "$domain"; wizard_set "$temp" HARBOR_DOMAIN "$harbor_domain"
        wizard_set "$temp" ARTIFACT_FILE "$artifact"; wizard_set "$temp" DEPS_MODE iso
        if (load_env "$temp"); then break; fi
        rm -f "$temp"
        printf '组合配置未通过校验，已保留节点清单，请修改相关选项；旧配置未覆盖。\n'
    done
    log '计算归档 SHA256，请稍候（该摘要固定本次选择，交付来源仍需核对随包摘要）'
    wizard_set "$temp" ARTIFACT_SHA256 "$(sha256_file "$artifact")"
    [ ! -f "$target" ] || cp -p "$target" "$target.bak.$(date +%Y%m%dT%H%M%S).$$"
    chmod 600 "$temp"; mv "$temp" "$target"
    log "配置已保存: ${target}"
}
wizard_credentials() {
    local line
    if [ "$COMPONENTS" != k8s ] && { [ "$stage" = all ] || [ "$stage" = install ] || [ "$stage" = resume ] || [ "$stage" = redeploy-run ]; }; then
        ask_secret HARBOR_PASSWORD 'Harbor admin 密码（隐藏输入；必须设置，回车仅保留已设置值）: '
        validate_password
    fi
    if [ "$stage" = all ] || [ "$stage" = init ]; then
        while IFS= read -r line; do
            parse_node "$line"
            if [ "$NODE_CONNECTION" = ssh ] && [ -n "$NODE_PASS_ENV" ] && [ -z "${!NODE_PASS_ENV:-}" ]; then
                ask_secret "$NODE_PASS_ENV" "$NODE_NAME SSH 密码（隐藏输入；已有免密可直接回车）: "
            fi
        done < <(node_lines)
    fi
}
silent_preflight() {
    local line
    if [ "$stage" = all ] || [ "$stage" = init ]; then
        while IFS= read -r line; do
            parse_node "$line"
            [[ "$NODE_DATA_MODE" = existing || "$NODE_DATA_MODE" = native ]] || die '静默模式仅支持 existing/native 数据策略，请先人工准备挂载或明确使用根盘'
        done < <(node_lines)
    fi
    if [ "$COMPONENTS" != k8s ] && { [ "$stage" = all ] || [ "$stage" = install ]; }; then validate_password; fi
}

. "$ROOT/lib/wizard-edit.sh"

. "$ROOT/lib/wizard-workers.sh"

# 执行前仅打印运维必需的白名单字段，不打印环境变量、密码或证书正文。
# 展示本次实际使用的快照；auto 表示稍后仍需人工选择磁盘，并非自动格式化。
wizard_summary() {
    local line
    printf '\n=== 执行前摘要 ===\n操作：%s\n配置：%s\n范围：%s\n' "$stage" "$ENV_FILE" "$COMPONENTS"
    if [ "$COMPONENTS" != harbor ]; then
        printf 'Kubernetes：%s；API：%s / %s:%s；域名：%s\n' "$KUBE_VERSION" "$ENDPOINT_TYPE" "${ENDPOINT_ADDRESS:-节点地址}" "$ENDPOINT_PORT" "$K8S_DOMAIN"
        printf 'Pod：%s；Service：%s；本地 PV：%s（%s）\n' "$POD_CIDR" "$SERVICE_CIDR" "$LOCAL_STORAGE" "$LOCAL_PATH"
    fi
    printf 'Harbor：%s:%s；模式：%s；VIP：%s\n' "$HARBOR_DOMAIN" "$HARBOR_PORT" "$REGISTRY_MODE" "${HARBOR_VIP:-无}"
    while IFS= read -r line; do
        parse_node "$line"
        printf '  %s | 连接 %s / 内部 %s | %s | %s / %s | 数据 %s / %s / %s\n'             "$NODE_NAME" "$NODE_ADDRESS" "$NODE_INTERNAL" "$NODE_ROLES" "$NODE_ARCH" "$NODE_OS" "$NODE_DATA" "$NODE_DATA_MODE" "${NODE_DEVICE:-未指定设备}"
    done < <(active_node_lines)
    printf 'NFS：%s；节点：%s；服务端：%s；目录：%s\n' "$NFS_MODE" "${NFS_NODE:-无}" "${NFS_SERVER:-无}" "$NFS_PATH"
    printf 'SSH：%s；NTP：%s；时间源节点：%s；上游：%s；允许本地时间源：%s\n' "$SSH_AUTH_MODE" "$NTP_MODE" "${NTP_NODE:-无}" "${NTP_SERVERS:-无}" "$NTP_ALLOW_LOCAL"
    nfs_notice
    printf '离线归档：%s\n状态目录：%s\n' "${ARTIFACT_FILE:-未填写}" "$STATE_DIR"
    printf 'auto 策略将在初始化时选择磁盘；格式化仍需要单独确认。\n'
}
