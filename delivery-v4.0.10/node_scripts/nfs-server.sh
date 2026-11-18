#!/usr/bin/env bash
set -euo pipefail
path="$1"; clients="$2"; cluster="$3"; uid="$4"; gid="$5"
action="${6:-apply}"
test "$(id -u)" = 0
command -v exportfs >/dev/null
test ! -L "$path"
[ "$action" != apply ] || mkdir -p /etc/exports.d
config="/etc/exports.d/rise-${cluster}.exports"
test ! -L "$config"
# Never replace site exports or recursively chown existing content.
shopt -s nullglob
for file in /etc/exports /etc/exports.d/*.exports; do
    [ -f "$file" ] && [ "$file" != "$config" ] || continue
    if awk -v p="$path" '$0 !~ /^[[:space:]]*#/ && $1==p {found=1} END {exit !found}' "$file"; then
        echo 'NFS 路径已有现场导出配置，请改用 existing 模式' >&2; exit 1
    fi
done
if [ "$action" = apply ] && [ ! -e "$path" ]; then
    mkdir -p "$path"; chown "$uid:$gid" "$path"; chmod 0770 "$path"
fi
test -d "$path"
tmp=$(mktemp /tmp/rise-exports.XXXXXX)
trap 'rm -f "$tmp"' EXIT
{
    printf '# rise-managed:%s\n' "$cluster"
    printf '%s' "$path"
    for client in $clients; do printf ' %s(rw,sync,root_squash,no_subtree_check,anonuid=%s,anongid=%s)' "$client" "$uid" "$gid"; done
    printf '\n'
} > "$tmp"
if [ -e "$config" ]; then
    grep -qxF "# rise-managed:$cluster" "$config" || { echo '拒绝覆盖非受管 NFS 配置' >&2; exit 1; }
fi
if [ "$action" = apply ]; then
    # Atomic replace on the target filesystem.
    installed=$(mktemp /etc/exports.d/.rise.XXXXXX)
    cat "$tmp" > "$installed"; chmod 644 "$installed"; mv "$installed" "$config"
else cmp -s "$tmp" "$config" || { echo 'NFS 导出配置与计划不一致' >&2; exit 1; }; fi
. /etc/os-release
unit=nfs-server; [ "$ID" != ubuntu ] || unit=nfs-kernel-server
if [ "$action" = apply ]; then systemctl enable --now "$unit" >&2; exportfs -ra; fi
systemctl is-active --quiet "$unit"
exportfs -v
