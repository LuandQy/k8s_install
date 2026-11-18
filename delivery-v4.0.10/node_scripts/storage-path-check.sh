#!/usr/bin/env bash
# Read-only destination validation: mode path [fstab_file]. Never mkdir/mount/format.
set -euo pipefail
mode="$1"; target="${2%/}"; fstab="${3:-/etc/fstab}"
fail() { printf '[目录不可用] %s\n' "$*" >&2; exit 2; }
[[ "$target" =~ ^/[a-zA-Z0-9_./-]+$ && "$target" != *'..'* ]] || fail '请输入有效的绝对目录路径'
case "$target" in /|/etc|/etc/*|/usr|/usr/*|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/var|/var/lib|/var/lib/docker|/var/lib/docker/*|/var/lib/containerd|/var/lib/containerd/*|/var/lib/kubelet|/var/lib/kubelet/*) fail '不能将系统目录或组件原生目录作为数据盘挂载目录';; esac
case "$mode" in format|existing) ;; *) fail '目录检查模式无效';; esac
probe="$target"
while :; do
    [ ! -L "$probe" ] || fail "路径包含软链接: ${probe}，请填写真实挂载路径"
    if [ "$probe" = / ]; then break; fi
    probe=$(dirname "$probe")
done
if [ -e "$target" ]; then [ -d "$target" ] || fail '目标路径是文件，不是目录'; fi
probe="$target"
while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
[ -d "$probe" ] || fail '目标父路径不是目录'
if [ "$mode" = format ]; then
    ! mountpoint -q "$target" || fail '目标目录已经挂载，不能格式化覆盖；可返回选择 existing'
    if [ -d "$target" ]; then
        contents=$(ls -A "$target") || fail '无法读取目标目录内容'
        [ -z "$contents" ] || fail "目录非空: ${target}。不会清理或挂载遮蔽已有数据，请重新输入空目录"
    fi
    if [ -f "$fstab" ] && awk -v p="$target" '$0 !~ /^[[:space:]]*#/ && $2==p {found=1} END{exit !found}' "$fstab"; then
        fail 'fstab 已有目标路径配置，请换目录或人工核实后重试'
    fi
else
    root_dev=$(findmnt -n -o MAJ:MIN -T /)
    data_dev=$(findmnt -n -o MAJ:MIN -T "$probe")
    [ -n "$data_dev" ] && [ "$data_dev" != "$root_dev" ] || fail '该目录仍在根分区：existing 仅复用已挂载的独立数据盘；请返回选空盘编号或 native'
    mount_root=$(findmnt -n -o TARGET -T "$probe")
    [ -n "$mount_root" ] && [ "$mount_root" != / ] || fail '没有独立数据盘挂载点'
    findmnt --fstab --tab-file "$fstab" --target "$mount_root" >/dev/null || fail '已有数据盘未配置 fstab，请先人工配置持久挂载'
fi
printf '[OK] 目录检查通过: %s（%s）\n' "$target" "$mode"
