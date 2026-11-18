#!/usr/bin/env bash
# 节点录入模块：只生成配置和读取系统信息，不安装软件、不修改远程磁盘。
# WIZARD_NODE 是单行结果，WIZARD_NODES 是最终清单；密码只保存在当前进程环境。

wizard_platform() {
    # 参数：uname -m、发行版 ID、VERSION_ID。无法严格匹配时交给手动选择。
    # Kylin 的 V10 不能证明 SP3-2403，因此不把所有 V10 自动映射到同一 ISO。
    DETECTED_ARCH=; DETECTED_OS=
    case "$1" in x86_64|amd64) DETECTED_ARCH=amd64;; aarch64|arm64) DETECTED_ARCH=arm64;; *) return 1;; esac
    case "$2:$3" in
        ubuntu:22.04) DETECTED_OS=ubuntu-22.04-debs;;
        ubuntu:24.04) DETECTED_OS=ubuntu-24.04-debs;;
        *) return 1;;
    esac
}
wizard_detect_platform() {
    local output machine id version
    local script='set -e; . /etc/os-release; printf "%s|%s|%s\n" "$(uname -m)" "$ID" "$VERSION_ID"'
    if [ "$NODE_CONNECTION" = local ]; then
        output=$(bash -c "$script" 2>/dev/null) || return 1
    else
        # 只使用已有密钥；不能连接时走手选，不在探测阶段下发公钥或读取密码。
        # 独立 known_hosts 模式只接受预先固定的公钥；默认保持 accept-new。
        ssh_host_options
        local -a args=(-T -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -p "$NODE_PORT" "${SSH_HOST_OPTIONS[@]}")
        if [ -f "${SSH_KEY:-/root/.ssh/rise_deploy}" ]; then args+=(-i "${SSH_KEY:-/root/.ssh/rise_deploy}"); fi
        output=$(printf '%s\n' "$script" | ssh "${args[@]}" "$NODE_USER@$NODE_ADDRESS" 'bash -s' 2>/dev/null) || return 1
    fi
    IFS='|' read -r machine id version <<< "$output"
    wizard_platform "$machine" "$id" "$version"
}
wizard_node() {
    local number="$1" previous="${2:-}" choice default_connection=2 default_role default_mode=1
    # 编辑时以原值为默认值。变量名跟随节点保存，删除或重排不会串用 SSH 密码。
    if [ -n "$previous" ]; then parse_node "$previous"; else
        NODE_NAME="node$number"; NODE_ADDRESS=; NODE_INTERNAL=; NODE_USER=root; NODE_PORT=22
        NODE_ARCH=amd64; NODE_OS=ubuntu-24.04-debs; NODE_CONNECTION=ssh
        NODE_ROLES=worker; NODE_DATA=/data; NODE_DATA_MODE=auto; NODE_DEVICE=; NODE_PASS_ENV="NODE${number}_PASSWORD"
        if [ "$number" = 1 ]; then NODE_ADDRESS=$(recommended_ip); NODE_ROLES=control_plane,worker,registry; fi
    fi
    if [ "${WIZARD_SCOPE:-cluster}" = workers ] && [ -z "$previous" ]; then
        NODE_NAME="worker$number"; NODE_ADDRESS=''; NODE_ROLES=worker
        NODE_PASS_ENV="WORKER${number}_PASSWORD"
    fi
    printf '\n--- 节点 %s ---\n' "$number"
    ask_valid '节点名称（小写字母开头）' "$NODE_NAME" name; NODE_NAME="$REPLY"
    ask_valid '连接 IP' "$NODE_ADDRESS" ipv4; NODE_ADDRESS="$REPLY"
    ask_valid '节点内部 IP（通常同连接 IP）' "${NODE_INTERNAL:-$NODE_ADDRESS}" ipv4; NODE_INTERNAL="$REPLY"
    if [ "$NODE_CONNECTION" = local ] || { [ -z "$previous" ] && [ "$NODE_ADDRESS" = "$(recommended_ip)" ]; }; then default_connection=1; fi
    ask_valid '连接方式：1 本机；2 SSH' "$default_connection" '1|2'
    NODE_CONNECTION=ssh; [ "$REPLY" != 1 ] || NODE_CONNECTION=local
    if [ "$NODE_CONNECTION" = ssh ]; then
        ask_valid 'SSH 用户（普通用户须免密 sudo）' "$NODE_USER" user; NODE_USER="$REPLY"
        ask_valid 'SSH 端口' "$NODE_PORT" port; NODE_PORT="$REPLY"
    else NODE_USER=root; NODE_PORT=22; fi
    printf '正在只读识别系统和架构；SSH 未打通时可手动选择。\n'
    if wizard_detect_platform; then
        NODE_ARCH="$DETECTED_ARCH"; NODE_OS="$DETECTED_OS"
        printf '识别结果：%s / %s\n' "$NODE_ARCH" "$NODE_OS"
    else
        printf '未能明确识别支持的系统，请按目标节点实际信息选择。Kylin 须核对 V10SP3-2403。\n'
        choice=1; [ "$NODE_ARCH" != arm64 ] || choice=2
        ask_valid '架构：1 amd64；2 arm64' "$choice" '1|2'
        case "$REPLY" in 1) NODE_ARCH=amd64;; 2) NODE_ARCH=arm64;; esac
        case "$NODE_OS" in ubuntu-22.04-debs) choice=1;; kylin-*) choice=3;; *) choice=2;; esac
        ask_valid '系统：1 Ubuntu 22.04；2 Ubuntu 24.04；3 Kylin V10SP3-2403' "$choice" '1|2|3'
        case "$REPLY" in 1) NODE_OS=ubuntu-22.04-debs;; 2) NODE_OS=ubuntu-24.04-debs;; 3) NODE_OS=kylin-v10SP3-2403-rpms;; esac
    fi
    if [ "${WIZARD_SCOPE:-cluster}" = workers ]; then
        NODE_ROLES=worker
        printf '扩容角色固定为 worker。\n'
    else
        default_role=
        if has_role control_plane; then default_role=1; fi
        if has_role worker; then default_role="${default_role:+$default_role,}2"; fi
        if has_role registry; then default_role="${default_role:+$default_role,}3"; fi
        ask_valid '角色（可多选，按顺序用逗号分隔）：1 控制平面；2 Worker；3 Harbor' "${default_role:-2}" '1|2|3|1,2|1,3|2,3|1,2,3'
        choice="$REPLY"
        NODE_ROLES=
        if [[ "$choice" == *1* ]]; then NODE_ROLES=control_plane; fi
        if [[ "$choice" == *2* ]]; then NODE_ROLES="${NODE_ROLES:+$NODE_ROLES,}worker"; fi
        if [[ "$choice" == *3* ]]; then NODE_ROLES="${NODE_ROLES:+$NODE_ROLES,}registry"; fi
    fi
    ask_valid '数据根目录' "$NODE_DATA" path; NODE_DATA="$REPLY"
    case "$NODE_DATA_MODE" in existing) default_mode=2;; native) default_mode=3;; esac
    ask_valid '数据策略：1 初始化时选择磁盘；2 已挂载独立数据盘；3 使用根盘原生目录' "$default_mode" '1|2|3'
    case "$REPLY" in 1) NODE_DATA_MODE=auto;; 2) NODE_DATA_MODE=existing;; 3) NODE_DATA_MODE=native;; esac
    # 不保留旧的格式化设备选择；真实初始化仍重新枚举磁盘并要求确认串。
    WIZARD_NODE="$NODE_NAME|$NODE_ADDRESS|$NODE_INTERNAL|$NODE_USER|$NODE_PORT|$NODE_ARCH|$NODE_OS|$NODE_ROLES|$NODE_CONNECTION|$NODE_DATA|$NODE_DATA_MODE||$NODE_PASS_ENV"
}
wizard_nodes() {
    local -a rows=()
    local i selection next_id=1 count row slot
    if [ -n "${WIZARD_NODES:-}" ]; then
        while IFS= read -r row; do [ -z "$row" ] || rows+=("$row"); done <<< "$WIZARD_NODES"
        next_id=$((${#rows[@]}+1))
        # 组合校验失败返回清单时，不按剩余行数复用已用过的密码变量编号。
        # 例如删除 node2 后仍有 NODE3_PASSWORD，新节点必须从 4 开始。
        for row in "${rows[@]}"; do
            parse_node "$row"
            if [[ "$NODE_PASS_ENV" =~ ^NODE([0-9]+)_PASSWORD$ ]]; then
                slot="${BASH_REMATCH[1]}"
                if [ "$slot" -ge "$next_id" ]; then next_id=$((slot+1)); fi
            fi
        done
    else
        wizard_node "$next_id" ''; rows+=("$WIZARD_NODE"); next_id=$((next_id+1))
    fi
    while :; do
        printf '\n%-4s %-16s %-16s %-8s %s\n' 序号 节点 IP 架构 角色
        for ((i=0;i<${#rows[@]};i++)); do
            parse_node "${rows[$i]}"
            printf '%-4s %-16s %-16s %-8s %s\n' "$((i+1))" "$NODE_NAME" "$NODE_ADDRESS" "$NODE_ARCH" "$NODE_ROLES"
        done
        ask_valid '1 添加节点；2 修改节点；3 删除节点；0 完成节点清单' 0 '0|1|2|3'
        selection="$REPLY"; count=${#rows[@]}
        case "$selection" in
            0)
                if [ "$count" -eq 0 ]; then printf '至少保留一个节点。\n'; continue; fi
                WIZARD_NODES=$(printf '%s\n' "${rows[@]}")
                # 这里只检查节点之间的重名/地址和控制平面数量；完整校验在写配置前执行。
                if ! wizard_nodes_valid "$WIZARD_NODES"; then continue; fi
                return;;
            1) wizard_node "$next_id" ''; rows+=("$WIZARD_NODE"); next_id=$((next_id+1));;
            2|3)
                [ "$count" -gt 0 ] || { printf '当前没有节点，请先添加。\n'; continue; }
                ask_valid '要操作的序号' 1 number
                i=$((10#$REPLY-1))
                if [ "$i" -lt 0 ] || [ "$i" -ge "$count" ]; then printf '该序号不存在。\n'; continue; fi
                if [ "$selection" = 2 ]; then
                    wizard_node "$((i+1))" "${rows[$i]}"; rows[$i]="$WIZARD_NODE"
                else
                    unset 'rows[i]'
                    # 重新压紧数组下标；内容中的密码变量名不改变。
                    rows=("${rows[@]}")
                fi;;
        esac
    done
}
wizard_nodes_valid() {
    local nodes="$1" row names=' ' addresses=' ' masters=0 locals=0
    while IFS= read -r row; do
        parse_node "$row"
        if [[ "$names" = *" $NODE_NAME "* || "$addresses" = *" $NODE_INTERNAL "* ]]; then printf '节点名称或内部 IP 重复，请修改后再完成。\n'; return 1; fi
        names="$names$NODE_NAME "; addresses="$addresses$NODE_INTERNAL "
        if [ "${WIZARD_SCOPE:-cluster}" = workers ] && [ "$NODE_ROLES" != worker ]; then
            printf '扩容仅允许 worker 角色。\n'; return 1
        fi
        if has_role control_plane; then masters=$((masters+1)); fi
        if [ "$NODE_CONNECTION" = local ]; then locals=$((locals+1)); fi
    done <<< "$nodes"
    if [ "$locals" -gt 1 ]; then printf '本机连接只能有一个，请将其他节点改成 SSH。\n'; return 1; fi
    if [ "${WIZARD_SCOPE:-cluster}" != workers ] && [ "${CLI_COMPONENTS:-all}" != harbor ] && [ "$masters" -ne 1 ] && [ "$masters" -ne 3 ]; then printf '控制平面必须为 1 或 3 个，请修改节点清单。\n'; return 1; fi
}

