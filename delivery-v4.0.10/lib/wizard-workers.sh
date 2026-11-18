#!/usr/bin/env bash
# 从本地受管集群记录选择扩容目标。仅列出有身份记录的目录，不加载其中配置。
# 真正读取时仍由 load_managed_state 校验来源及 SHA256；不自动接管外部集群。
wizard_select_state() {
    local dir i choice
    local -a candidates=()
    for dir in "$ROOT"/state/*; do
        [ ! -f "$dir/identity.json" ] || candidates+=("$dir")
    done
    printf '\n选择已有集群：\n'
    for ((i=0;i<${#candidates[@]};i++)); do printf '%s. %s\n' "$((i+1))" "${candidates[$i]}"; done
    printf '0. 手动输入状态目录（自定义位置）\n'
    choice=0; [ "${#candidates[@]}" -ne 1 ] || choice=1
    while :; do
        ask_default '集群编号' "$choice"
        if [ "$REPLY" = 0 ]; then
            ask_valid '已有集群状态目录' "${STATUS_STATE_DIR:-$ROOT/state/rise}" path
            WIZARD_STATE_DIR="$REPLY"; return
        fi
        if [[ "$REPLY" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$REPLY" -le "${#candidates[@]}" ]; then
            WIZARD_STATE_DIR="${candidates[$((10#$REPLY-1))]}"; return
        fi
        printf '请输入列出的编号。\n'
    done
}
# 只生成新增清单，不在向导内初始化节点。与旧节点合并校验后才保存。
# 在子进程中加载集群记录，避免把旧集群参数留在主菜单进程里。
wizard_workers() (
    local state="$1" target="$2" old_nodes temp
    RECOVERY_CONTEXT=expansion
    load_managed_state "$state"
    assert_no_pending_expansion
    old_nodes="$NODES"
    WIZARD_SCOPE=workers; WIZARD_NODES=''
    wizard_nodes
    NODES="$old_nodes"$'\n'"$WIZARD_NODES"
    validate_env
    printf '\n扩容目标：%s\nKubernetes：%s\n只添加上述 worker；原有节点参数保持不变。\n' "$STATE_DIR" "$KUBE_VERSION"
    ask_valid '1 保存新增清单并继续扩容；0 取消' 0 '0|1'
    [ "$REPLY" = 1 ] || return 0
    [ ! -e "$target" ] || die "新增清单已存在，拒绝覆盖：$target"
    umask 077; temp=$(mktemp "${target}.XXXXXX")
    trap 'rm -f "$temp"' EXIT
    printf '# 新增 worker 清单；密码只通过环境或终端输入。\nNEW_NODES=%q\n' "$WIZARD_NODES" > "$temp"
    chmod 600 "$temp"; mv "$temp" "$target"
    printf '新增清单：%s\n' "$target"
)
