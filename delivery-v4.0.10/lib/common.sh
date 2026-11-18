#!/usr/bin/env bash
# Shared shell functions. This file does not execute node operations when sourced.
#
# The delivery is Linux-only: mapfile (Bash 4.0+) and indirect expansion with
# defaults (${var:-}) are used throughout. macOS Bash 3.2 would otherwise fail
# much later with an unrelated "unbound variable" message, so fail up front.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 4 ]; }; then
    printf '[ERROR] 需要 Bash 4.4 或更高版本，当前为 %s。部署控制端必须使用 Linux（如 Ubuntu 22.04/24.04，Bash 5.x）。\n' "${BASH_VERSION:-unknown}" >&2
    exit 1
fi
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Prefer the shipped jq on the controller. The bundle checksum covers both builds.
case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64)
        if [ -x "$ROOT/tools/amd64/jq" ]; then export PATH="$ROOT/tools/amd64:$PATH"; fi;;
    Linux:aarch64|Linux:arm64)
        if [ -x "$ROOT/tools/arm64/jq" ]; then export PATH="$ROOT/tools/arm64:$PATH"; fi;;
esac
# 日志级别：RISE_LOG_LEVEL=quiet|info|debug（默认 info）。
# info 输出 INFO/WARN/ERROR；debug 额外输出 DEBUG、模板/命令追踪和失败位置。
# 交付要求日志不做脱敏，因此 debug 及正常日志都可能包含完整命令与凭据；
# 日志目录须按凭据资料保管，不能随公开包或问题截图外发。
RISE_LOG_LEVEL="${RISE_LOG_LEVEL:-info}"
case "$RISE_LOG_LEVEL" in
    quiet|info|debug) ;;
    *) printf '[ERROR] RISE_LOG_LEVEL 必须为 quiet/info/debug，当前为 %s\n' "$RISE_LOG_LEVEL" >&2; exit 1;;
esac
export RISE_LOG_LEVEL
log_is_debug() { [ "$RISE_LOG_LEVEL" = debug ]; }
log_is_quiet() { [ "$RISE_LOG_LEVEL" = quiet ]; }
# 错误上下文只输出阶段和目录，不输出命令、参数或环境。
# 不覆盖部署回执的 EXIT trap；已有失败状态保存逻辑仍负责记录实际部署进度。
die() {
    printf '[ERROR] %s\n' "$*" >&2
    printf '当前阶段：%s\n' "${ERROR_PHASE:-${stage:-配置与前置校验}}" >&2
    [ -z "${RUN_DIR:-}" ] || printf '运行记录：%s\n' "$RUN_DIR" >&2
    if log_is_debug; then
        printf '[DEBUG] 失败位置：%s:%s；函数 %s\n' "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]:-main}" >&2
    fi
    recovery_hint >&2
    exit 1
}
# 调用入口显式设置上下文，子脚本继承；不能仅凭有日志目录就推荐续跑安装。
# 扩容优先级最高，避免其 init/check 子进程误导用户重装已有集群。
recovery_hint() {
    case "${RECOVERY_CONTEXT:-${stage:-config}}" in
        expansion) printf '处理建议：人工核对扩容记录、新旧节点及集群成员；不要直接重试、删除记录或续跑整套安装。\n';;
        init|keys|storage|kernel) printf '处理建议：核对日志与实际磁盘/挂载后，先确认接入已完成（./deploy.sh access --env 原配置文件），再执行 ./deploy.sh prepare --env 原配置文件；没有接入记录时使用 ./deploy.sh all。不要直接续跑安装。\n';;
        check|verify) printf '处理建议：根据报告修复后重新检查，使用原来的 check/verify 命令；检查失败本身不代表需要重装。\n';;
        deploy|install|resume|redeploy-run)
            printf '处理建议：先核对 ./deploy.sh status 和运行日志；仅有匹配的未完成部署回执时选择 resume，并保留原 --env 与 --components 参数。\n';;
        reset|redeploy) printf '处理建议：核对本地状态与实际集群，保留原参数进入维护操作；不要手动删除回执或绕过确认。\n';;
        *) printf '处理建议：修正输入或前置条件后重新执行；先用 ./deploy.sh status 查看记录，部分节点操作可能已生效。\n';;
    esac
}
log() { log_is_quiet || printf '[%s] [INFO] %s\n' "$(date '+%F %T')" "$*" >&2; }
log_warn() { log_is_quiet || printf '[%s] [WARN] %s\n' "$(date '+%F %T')" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; }
log_debug() { log_is_debug || return 0; printf '[%s] [DEBUG] %s\n' "$(date '+%F %T')" "$*" >&2; }
# --debug 在解析参数后才生效，因此追踪必须可延迟开启。
log_debug_apply_trace() {
    log_is_debug || return 0
    [ "${RISE_LOG_TRACE:-1}" = 0 ] && return 0
    PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
    trap 'rc=$?; printf "[%s] [DEBUG] 命令失败 rc=%s：%s:%s\n" "$(date "+%F %T")" "$rc" "${BASH_SOURCE[0]##*/}" "${LINENO}" >&2' ERR
}
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
json_quote() { printf '%s' "$1" | jq -Rs .; }
safe_path() {
    [[ "$1" =~ ^/[a-zA-Z0-9_./-]+$ && "$1" != *'..'* ]] || die "无效路径: $1"
    case "${1%/}" in ''|/etc|/var|/var/lib|/usr|/boot) die "拒绝危险路径: $1";; esac
}
ipv4() {
    local part oldifs="$IFS"; local -a octets
    IFS=. read -r -a octets <<< "$1"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for part in "${octets[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$part))" -le 255 ] || return 1
    done
}
ip_number() {
    local a b c d
    ipv4 "$1" || die "无效 IPv4: $1"
    IFS=. read -r a b c d <<< "$1"
    printf '%s\n' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}
cidr_bounds() {
    local address="${1%/*}" prefix="${1##*/}" number mask
    [[ "$1" = */* && "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -le 32 ] || die "无效 CIDR: $1"
    number="$(ip_number "$address")"
    if [ "$prefix" -eq 0 ]; then mask=0; else mask=$(( (0xffffffff << (32-prefix)) & 0xffffffff )); fi
    [ "$((number & mask))" -eq "$number" ] || die "CIDR 不是网络地址: $1"
    printf '%s %s\n' "$number" "$((number | (0xffffffff ^ mask)))"
}
has_role() { [[ ",$NODE_ROLES," = *",$1,"* ]]; }
parse_node() {
    IFS='|' read -r NODE_NAME NODE_ADDRESS NODE_INTERNAL NODE_USER NODE_PORT NODE_ARCH NODE_OS NODE_ROLES NODE_CONNECTION NODE_DATA NODE_DATA_MODE NODE_DEVICE NODE_PASS_ENV <<< "$1"
}
node_lines() { printf '%s\n' "$NODES" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d'; }
 . "$ROOT/lib/components.sh"
. "$ROOT/lib/config.sh"
new_run() {
    umask 077
    if [ -n "${RUN_DIR:-}" ]; then
        # --output 指定路径时仍禁止复用目录，避免覆盖上一次运行记录。
        [ ! -e "$RUN_DIR" ] || die 'RUN_DIR 已存在，请每次使用新目录'
        mkdir -p "$(dirname -- "$RUN_DIR")"
        mkdir "$RUN_DIR"
    else
        # redeploy 会 exec 回部署入口，PID 不变且可能仍处于同一秒。
        # mktemp 原子创建唯一目录，避免依赖时间精度或为了避碰而 sleep。
        mkdir -p "$ROOT/runs"
        RUN_DIR=$(mktemp -d "$ROOT/runs/$(date +%Y%m%dT%H%M%S)-$$.XXXXXX")
    fi
    RUN_DIR="$(cd "$RUN_DIR" && pwd)"
    export RUN_DIR
}
linux_root() {
    [ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ] || die '实际执行要求 Linux root，render 可在 macOS 执行'
}
controller_lock() {
    need flock
    # A child must retain the inherited open-file description. Reopening the
    # same inode creates a competing lock, even within one deployment tree.
    if [ ! /dev/fd/8 -ef /run/lock/rise-deploy-controller.lock ]; then
        exec 8>/run/lock/rise-deploy-controller.lock
    fi
    flock -n 8 || die '控制端已有部署操作执行中'
}
assert_no_pending_expansion() {
    [ ! -e "${STATE_DIR}.expansion" ] || die "存在未完成扩容，禁止按旧清单继续部署或删除；请先核对 ${STATE_DIR}.expansion 中的运行记录和全部节点"
}
nfs_notice() {
    [ "${COMPONENTS:-all}" != harbor ] && [ "${NFS_MODE:-none}" != none ] || return 0
    log '已选择 NFS：deps 安装匹配系统的服务端依赖，离线介质缺包即停止；services-init 配置并验收挂载读写。'
    log 'services-verify 验证临时挂载读写；CSI/PVC 和业务 UID/GID 权限仍需实机验收。'
}
nfs_preflight() {
    [ "${DELIVERY_PREPARE:-false}" != true ] || return 0
    [ "${COMPONENTS:-all}" != harbor ] && [ "$NFS_MODE" = new ] || return 0
    local row found=false
    while IFS= read -r row; do
        parse_node "$row"
        if [ "$NODE_NAME" = "$NFS_NODE" ]; then
            node_run "$ROOT/node_scripts/nfs-preflight.sh"
            found=true
        fi
    done < <(active_node_lines)
    [ "$found" = true ] || [ "${VALIDATION_SCOPE:-cluster}" = workers ] || die 'NFS 服务端不在活动节点清单中'
}
choose_kk() {
    local rel
    case "$(uname -m)" in x86_64|amd64) rel=tools/amd64/kk;; aarch64|arm64) rel=tools/arm64/kk;; *) die '控制机架构不支持';; esac
    KK="$ROOT/$rel"
    [ -x "$KK" ] || die "缺少可执行文件 $rel；请运行 ./tools/kk-fetch.sh --version $KK_VERSION --apply（二进制只保存在 tools/<arch>/kk）"
    local expected version_output actual_version
    expected="$(awk -v name="$rel" -v ver="$KK_VERSION" '!/^#/ && $2==name && $3==ver {print $1; exit}' "$ROOT/lib/kk-binaries.sha256")"
    [ -n "$expected" ] || die "发布校验记录中没有 $KK_VERSION / $rel 的摘要；请先运行 ./tools/kk-fetch.sh --version $KK_VERSION 核对后再更新记录"
    [ "$(sha256_file "$KK")" = "$expected" ] || die "kk 二进制摘要与发布校验记录不一致（$KK_VERSION / $rel）"
    version_output=$("$KK" version 2>&1) || die "kk version 执行失败: $version_output"
    actual_version=$(printf '%s\n' "$version_output" | jq -er '.gitVersion | select(type=="string")') || die "无法解析 kk 版本 JSON: $version_output"
    [ "$actual_version" = "$KK_VERSION" ] || die "kk 版本必须为 $KK_VERSION，实际为 $actual_version"
}
supported_kubernetes_versions() {
    python3 "$ROOT/lib/kubernetes-versions.py" --root "$ROOT" list
}
default_kubernetes_version() {
    python3 "$ROOT/lib/kubernetes-versions.py" --root "$ROOT" default
}
schema_default() {
    python3 "$ROOT/lib/schema-defaults.py" --root "$ROOT" --get "$1"
}
supported_kubekey_versions() {
    awk '!/^#/ && $2=="tools/amd64/kk" {print $3}' "$ROOT/lib/kk-binaries.sha256" | sort -uV
}
ssh_known_hosts_digest() {
    [ -f "$SSH_KNOWN_HOSTS" ] && [ -r "$SSH_KNOWN_HOSTS" ] && [ -s "$SSH_KNOWN_HOSTS" ] || die '独立 SSH known_hosts 文件不存在、不可读或为空；先通过可信控制台固定节点公钥'
    local digest
    digest=$(sha256_file "$SSH_KNOWN_HOSTS")
    [ -z "${SSH_KNOWN_HOSTS_SHA256:-}" ] || [ "$digest" = "$SSH_KNOWN_HOSTS_SHA256" ] || die 'SSH known_hosts 公钥文件摘要变化，拒绝连接'
    printf '%s\n' "$digest"
}
ssh_host_options() {
    SSH_HOST_OPTIONS=(-o StrictHostKeyChecking=accept-new)
    [ -n "${SSH_KNOWN_HOSTS:-}" ] || return 0
    safe_path "$SSH_KNOWN_HOSTS"
    ssh_known_hosts_digest >/dev/null
    # No user/global config or alternate trust source; never add/update host keys.
    SSH_HOST_OPTIONS=(-F /dev/null -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null
        -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o VerifyHostKeyDNS=no)
}
node_run() {
    local script_file="$1" input remote; shift
    input="$(mktemp "$RUN_DIR/.input.XXXXXX")"
    { printf 'set --'; printf ' %q' "$@"; printf '\n'; cat "$script_file"; } > "$input"
    local -a opts=( -T -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p "$NODE_PORT" )
    if [ "$NODE_CONNECTION" = ssh ]; then ssh_host_options; opts+=("${SSH_HOST_OPTIONS[@]}"); fi
    remote='bash -se'
    [ "${RUN_AS_USER:-0}" = 1 ] || [ "$NODE_USER" = root ] || remote='sudo -n bash -se'
    local rc=0
    if [ "$NODE_CONNECTION" = local ]; then
        bash -se < "$input" || rc=$?
    elif [ "${BOOTSTRAP:-0}" = 1 ] || [ "${SSH_AUTH_MODE:-bootstrap}" = password ]; then
        need sshpass
        [ -n "$NODE_PASS_ENV" ] && [ -n "${!NODE_PASS_ENV:-}" ] || die "缺少 $NODE_NAME 的 SSH 密码环境变量"
        SSHPASS="${!NODE_PASS_ENV}" sshpass -e ssh -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "${opts[@]}" "$NODE_USER@$NODE_ADDRESS" "$remote" < "$input" || rc=$?
    else
        ssh "${opts[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_KEY" "$NODE_USER@$NODE_ADDRESS" "$remote" < "$input" || rc=$?
    fi
    rm -f "$input"
    return "$rc"
}
node_upload() {
    local src="$1" dst="$2" quoted remote
    printf -v quoted '%q' "$dst"
    remote="umask 077; cat > $quoted"
    if [ "$NODE_CONNECTION" = local ]; then install -D -m 600 "$src" "$dst"; return; fi
    ssh_host_options
    local -a opts=(-T -o ConnectTimeout=10 -p "$NODE_PORT" "${SSH_HOST_OPTIONS[@]}")
    if [ "$NODE_USER" != root ]; then printf -v quoted '%q' "$remote"; remote="sudo -n bash -c $quoted"; fi
    if [ "${SSH_AUTH_MODE:-bootstrap}" = password ]; then
        need sshpass
        [ -n "$NODE_PASS_ENV" ] && [ -n "${!NODE_PASS_ENV:-}" ] || die "缺少 $NODE_NAME 的 SSH 密码环境变量"
        SSHPASS="${!NODE_PASS_ENV}" sshpass -e ssh -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "${opts[@]}" "$NODE_USER@$NODE_ADDRESS" "$remote" < "$src"
    else
        ssh "${opts[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_KEY" "$NODE_USER@$NODE_ADDRESS" "$remote" < "$src"
    fi
}
kk_ssh_preflight() {
    [ -n "${SSH_KNOWN_HOSTS:-}" ] || return 0
    local baseline="$1" row digest machine uuid host probe
    digest=$(ssh_known_hosts_digest)
    [ -s "$baseline" ] || die 'KubeKey 前置 SSH 身份基线缺失'
    log "KubeKey $KK_VERSION 自身不校验 SSH 主机公钥；现在仅执行独立严格 SSH/身份前置核验，不消除后续 KK 连接窗口"
    : > "$RUN_DIR/kk-ssh-preflight.jsonl"
    while IFS= read -r row; do
        parse_node "$row"; [ "$NODE_CONNECTION" = ssh ] || continue
        probe="$RUN_DIR/$NODE_NAME.kk-ssh-identity"
        node_run "$ROOT/node_scripts/access-probe.sh" > "$probe" 2> "$RUN_DIR/$NODE_NAME.kk-ssh.log" || die "$NODE_NAME KubeKey 前置严格 SSH/sudo 校验失败；查看节点 kk-ssh.log，未执行 KubeKey"
        { IFS= read -r machine; IFS= read -r uuid; IFS= read -r host; } < "$probe"
        jq -e --arg name "$NODE_NAME" --arg machine "$machine" --arg uuid "$uuid" \
            '[.[] | select(.name==$name)] | length==1 and .[0].machine_id==$machine and .[0].uuid==$uuid and ($machine|length)>0' "$baseline" >/dev/null || die "$NODE_NAME KubeKey 前置身份与基线不符，未执行 KubeKey"
        jq -n --arg name "$NODE_NAME" --arg address "$NODE_ADDRESS" --arg machine "$machine" --arg uuid "$uuid" \
            '{name:$name,address:$address,machine_id:$machine,uuid:$uuid,strict_ssh_preflight:"passed"}' >> "$RUN_DIR/kk-ssh-preflight.jsonl"
    done < <(active_node_lines)
    [ "$(ssh_known_hosts_digest)" = "$digest" ] || die 'KubeKey 前置核验期间 known_hosts 变化，未执行 KubeKey'
    jq -s --arg path "$SSH_KNOWN_HOSTS" --arg digest "$digest" \
        '{known_hosts:$path,known_hosts_sha256:$digest,nodes:.,kk_host_key_verification:"unsupported",connection_window_eliminated:false}' \
        "$RUN_DIR/kk-ssh-preflight.jsonl" > "$RUN_DIR/kk-ssh-preflight.json"
}
prompt() {
    [ "$NONINTERACTIVE" != true ] || die '无人值守模式不能代替磁盘选择或格式化确认，请使用已挂载的数据目录'
    [ -r /dev/tty ] && [ -w /dev/tty ] || die '该步骤需要交互终端'
    printf '%s' "$1" > /dev/tty
    IFS= read -r REPLY < /dev/tty || die '输入取消'
}
sha256_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
file_mode() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }
check_work_disk() {
    safe_path "$1"; mkdir -p "$1"
    local rootdev workdev
    rootdev="$(findmnt -n -o MAJ:MIN -T /)"; workdev="$(findmnt -n -o MAJ:MIN -T "$1")"
    [ -n "$workdev" ] || die '无法识别工作目录所在分区'
    if [ "$rootdev" = "$workdev" ]; then
        local line allowed="$ALLOW_ROOT_WORKDIR" available
        while IFS= read -r line; do
            parse_node "$line"
            if [ "$NODE_CONNECTION" = local ] && [ "$NODE_DATA_MODE" = native ]; then allowed=true; fi
        done < <(node_lines)
        [ "$allowed" = true ] || die '工作目录位于根分区，请使用独立数据盘；根盘控制端需显式设置 ALLOW_ROOT_WORKDIR=true'
        available=$(df -Pk "$1" | awk 'NR==2{print $4}')
        [[ "$available" =~ ^[0-9]+$ ]] && [ "$available" -ge "$((MIN_ROOT_FREE_GIB*1024*1024))" ] || die '控制端根分区可用空间不足'
        log "控制端工作目录使用根分区：$1；至少保留 ${MIN_ROOT_FREE_GIB} GiB 可用空间"
    fi
}
check_external_endpoint() {
    [ "$ENDPOINT_TYPE" = external ] || return 0
    bash "$ROOT/node_scripts/endpoint.sh" "$ENDPOINT_ADDRESS" "$ENDPOINT_PORT"
    local line
    while IFS= read -r line; do
        parse_node "$line"
        node_run "$ROOT/node_scripts/endpoint.sh" "$ENDPOINT_ADDRESS" "$ENDPOINT_PORT"
    done < <(node_lines)
}
# RISE_LOG_LEVEL=debug 时在 source 阶段开启追踪；子脚本继承变量后自行生效。
log_is_debug && log_debug_apply_trace
render_template() {
    local line name token prefix suffix
    while IFS= read -r line || [ -n "$line" ]; do
        while [[ "$line" =~ \$\{([A-Z][A-Z0-9_]*)\} ]]; do
            name="${BASH_REMATCH[1]}"; token="${BASH_REMATCH[0]}"
            [ "${!name+x}" = x ] || die "模板变量未定义: $name"
            prefix="${line%%"$token"*}"; suffix="${line#*"$token"}"
            line="$prefix${!name}$suffix"
        done
        printf '%s\n' "$line"
    done < "$1"
}
