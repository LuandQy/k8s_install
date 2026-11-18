#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "[ERROR] 初始化验收失败（行 %s）：请核对内核锁定、数据挂载及组件目录链接\n" "$LINENO" >&2' ERR
data="$1"; harbor="$2"; roles=",$3,"; local_path="$4"; nfs_path="$5"; mode="${6:-existing}"
test -f /etc/kubekey/rise/locked-kernel
test "$(cat /etc/kubekey/rise/locked-kernel)" = "$(uname -r)"
rootdev="$(findmnt -n -o MAJ:MIN -T /)"
verify_link() { test -d "$2"; test "$(readlink -f "$1")" = "$(readlink -f "$2")"; }
if [ "$mode" = native ]; then
    test "$(cat /etc/kubekey/rise/storage-mode)" = native
    if [[ "$roles" = *,registry,* ]]; then test ! -L /var/lib/docker; test ! -L "$harbor"; fi
    if [[ "$roles" = *,control_plane,* || "$roles" = *,worker,* ]]; then test ! -L /var/lib/containerd; test ! -L /var/lib/kubelet; fi
else
    # auto/format describe the initial preparation request. This script only
    # verifies its result and never prepares or formats storage.
    case "$mode" in existing|auto|format) ;; *) printf '[ERROR] 未知数据策略: %s\n' "$mode" >&2; exit 1;; esac
    test "$(findmnt -n -o MAJ:MIN -T "$data")" != "$rootdev"
    if [[ "$roles" = *,registry,* ]]; then verify_link /var/lib/docker "$data/docker"; verify_link "$harbor" "$data/harbor"; fi
    if [[ "$roles" = *,control_plane,* || "$roles" = *,worker,* ]]; then verify_link /var/lib/containerd "$data/containerd"; verify_link /var/lib/kubelet "$data/kubelet"; fi
fi
for path in "$local_path" "$nfs_path"; do
    [ "$path" != - ] || continue
    mkdir -p "$path"
    [ "$mode" = native ] || test "$(findmnt -n -o MAJ:MIN -T "$path")" != "$rootdev"
done
