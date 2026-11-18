#!/usr/bin/env bash
# Validate a chosen path without changing the target; return 2 to select a disk again.
select_storage_path() {
    local mode="$1" path="$NODE_DATA" status
    while :; do
        if [ "${NONINTERACTIVE:-false}" != true ]; then
            if [ "$mode" = format ]; then
                prompt "输入新数据盘挂载目录（back 返回选盘）[$path]: "
            else
                prompt "输入已有独立挂载盘上的目录（back 返回选盘）[$path]: "
            fi
            case "$REPLY" in back|cancel) return 2;; esac
            path="${REPLY:-$path}"
        fi
        if node_run "$ROOT/node_scripts/storage-path-check.sh" "$mode" "$path"; then
            NODE_DATA="${path%/}"; return 0
        else status=$?; fi
        [ "${NONINTERACTIVE:-false}" != true ] || die '静默模式数据目录检查失败，请修正配置'
        [ "$status" -eq 2 ] || die '节点目录检查执行失败，请处理连接或系统错误后重试'
        printf '请重新输入目录，或输入 back 返回磁盘选择。\n' >&2
    done
}
