#!/usr/bin/env bash
# Read-only OS/package-manager probe. Emits shell-friendly key=value lines.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(uname -s)" = Linux
. /etc/os-release
machine="$(uname -m)"
case "$machine" in
    x86_64|amd64) arch=amd64;;
    aarch64|arm64) arch=aarch64;;
    *) arch="$machine";;
esac
manager=''
for candidate in apt-get dnf yum; do
    if command -v "$candidate" >/dev/null 2>&1; then manager="$candidate"; break; fi
done
printf 'RISE_PROBE_HOSTNAME=%s\n' "$(hostname)"
printf 'RISE_PROBE_ID=%s\n' "${ID:-}"
printf 'RISE_PROBE_VERSION_ID=%s\n' "${VERSION_ID:-}"
printf 'RISE_PROBE_CODENAME=%s\n' "${VERSION_CODENAME:-}"
printf 'RISE_PROBE_ARCH=%s\n' "$arch"
printf 'RISE_PROBE_MACHINE=%s\n' "$machine"
printf 'RISE_PROBE_PKG_MANAGER=%s\n' "$manager"
