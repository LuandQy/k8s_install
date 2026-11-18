#!/usr/bin/env bash
# Read-only node identity, conflict and storage inspection.
set -euo pipefail
test "$(uname -s)" = Linux || { echo '仅支持 Linux 节点' >&2; exit 1; }
test "$(id -u)" -eq 0 || { echo '检查需要 root 或免密 sudo' >&2; exit 1; }
for c in lsblk findmnt ip systemctl blkid wipefs; do
    command -v "$c" >/dev/null || { echo "缺少检查命令: $c" >&2; exit 1; }
done
. /etc/os-release
printf 'RISE_OS=%s\nRISE_OS_VERSION=%s\n' "$ID" "$VERSION_ID"
printf 'RISE_OS_DETAIL=%s\n' "${VERSION:-}"
printf 'RISE_ARCH=%s\nRISE_KERNEL=%s\nRISE_HOSTNAME=%s\n' "$(uname -m)" "$(uname -r)" "$(hostname)"
printf 'RISE_CPU_CORES=%s\nRISE_MEM_KB=%s\n' "$(nproc)" "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
printf 'RISE_IPS=%s\n' "$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | xargs)"
printf 'RISE_MACHINE_ID=%s\n' "$(cat /etc/machine-id)"
printf 'RISE_UUID=%s\n' "$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)"
for c in kubelet kubeadm kubectl containerd docker nerdctl; do
    if command -v "$c" >/dev/null; then
        printf 'RISE_BINARY=%s\n' "$c"
        if [ "$c" = kubelet ] || [ "$c" = kubeadm ]; then printf 'RISE_CONFLICT=已有K8s二进制:%s\n' "$c"; fi
    fi
done
for s in kubelet containerd docker etcd harbor; do
    if systemctl is-active --quiet "$s"; then printf 'RISE_CONFLICT=运行中的服务:%s\n' "$s"; fi
done
for d in /etc/kubernetes /var/lib/etcd /etc/cni/net.d; do
    if [ -d "$d" ] && [ -n "$(ls -A "$d")" ]; then printf 'RISE_CONFLICT=已有配置或数据:%s\n' "$d"; fi
done
if command -v ss >/dev/null; then
    for p in 2379 2380 6443 "${3:-8443}" 10250 10257 10259; do
        if ss -H -lnt | awk '{print $4}' | grep -qE ":${p}$"; then printf 'RISE_CONFLICT=端口占用:%s\n' "$p"; fi
    done
else
    echo 'RISE_CONFLICT=无法检查端口:缺少ss'
fi
if [ "${1:-0}" != 0 ] && ss -H -lnt | awk '{print $4}' | grep -qE ":${1}$"; then
    printf 'RISE_CONFLICT=仓库端口占用:%s\n' "$1"
fi
if [ "${2:-0}" = 1 ]; then
    shopt -s nullglob
    for file in /etc/exports /etc/exports.d/*.exports; do
        [ -f "$file" ] || continue
        if [ "$file" = "/etc/exports.d/rise-${5:-}.exports" ] && grep -qxF "# rise-managed:${5:-}" "$file"; then continue; fi
        if awk -v path="${4:-}" '$0 !~ /^[[:space:]]*#/ && $1==path {found=1} END {exit !found}' "$file"; then
            echo 'RISE_CONFLICT=目标NFS路径已有非受管导出配置，请改为 existing'
        fi
    done
fi
echo 'RISE_ROUTES_BEGIN'
ip -j -4 route show
echo 'RISE_ROUTES_END'
echo 'RISE_LINKS_BEGIN'
ip -j link show
echo 'RISE_LINKS_END'
echo 'RISE_MOUNTS_BEGIN'
findmnt -J -o TARGET,SOURCE,FSTYPE,OPTIONS,SIZE,AVAIL
echo 'RISE_MOUNTS_END'
echo 'RISE_BLOCKS_BEGIN'
lsblk -b -J -p -o NAME,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT,RO,PKNAME
echo 'RISE_BLOCKS_END'
