#!/usr/bin/env bash
# A bounded mount/read/write probe. Never add fstab entries or delete user files.
set -euo pipefail
server="$1"; path="$2"; version="$3"
test "$(id -u)" = 0
command -v timeout >/dev/null
tmp=$(mktemp -d /tmp/rise-nfs-probe.XXXXXX); probe=''
cleanup() {
    local rc=$?
    if mountpoint -q "$tmp"; then
        [ -z "$probe" ] || timeout 10 rm -f -- "$probe" || rc=1
        timeout 10 umount "$tmp" || rc=1
    fi
    if ! mountpoint -q "$tmp"; then rmdir "$tmp" || rc=1; else echo "验收挂载未卸载: $tmp" >&2; fi
    trap - EXIT; exit "$rc"
}
trap cleanup EXIT
timeout 20 mount -t nfs -o "vers=$version,soft,timeo=20,retrans=1" "$server:$path" "$tmp"
probe=$(timeout 10 mktemp "$tmp/.rise-probe.XXXXXXXX")
token="rise-nfs-$$-$(date +%s)"
printf '%s\n' "$token" | timeout 10 tee "$probe" >/dev/null
[ "$(timeout 10 cat "$probe")" = "$token" ]
printf 'mount_read_write=passed\n'
