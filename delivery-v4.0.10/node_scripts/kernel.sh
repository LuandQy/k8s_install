#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" -eq 0
. /etc/os-release
kernel="$(uname -r)"
mkdir -p /etc/kubekey/rise
# WSL kernels are supplied by Windows and have no distribution kernel package
# to pin. This branch is for local verification only; real hosts keep the
# package-hold checks below.
if grep -qi microsoft /proc/version 2>/dev/null; then
    printf '%s
' "$kernel" > /etc/kubekey/rise/locked-kernel
    printf 'WSL 内核由 Windows 管理，跳过内核包锁定: %s
' "$kernel"
    exit 0
fi
if [ "$ID" = ubuntu ]; then
    command -v apt-mark >/dev/null
    mapfile -t packages < <(dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' 'linux-*' 2>/dev/null |
        awk '$1=="installed" && $2 ~ /^linux-(image|headers|modules|generic|virtual|signed|lowlatency)/ {print $2}')
    test "${#packages[@]}" -gt 0 || { echo '未找到已安装内核包' >&2; exit 1; }
    dpkg-query -W "linux-image-$kernel" >/dev/null || { echo '当前内核包无法匹配，人工检查' >&2; exit 1; }
    apt-mark hold "${packages[@]}"
    for pkg in "${packages[@]}"; do apt-mark showhold | grep -qxF "$pkg"; done
elif [ "$ID" = kylin ] || [ "$ID" = '"kylin"' ]; then
    rpm -q "kernel-$kernel" >/dev/null || { echo '当前内核包无法匹配，人工检查' >&2; exit 1; }
    # Exact versionlock plugin availability differs across Kylin images. Package
    # manager exclusion prevents future transactions from updating kernel packages.
    for conf in /etc/yum.conf /etc/dnf/dnf.conf; do
        [ -f "$conf" ] || continue
        cp -an "$conf" "$conf.rise.bak"
        if ! grep -q '^exclude=.*kernel\*' "$conf"; then
            if grep -q '^exclude=' "$conf"; then
                sed -i '/^exclude=/s/$/ kernel*/' "$conf"
            else
                sed -i '/^\[main\]/a exclude=kernel*' "$conf"
            fi
        fi
        grep -q '^exclude=.*kernel\*' "$conf"
    done
else
    echo "不支持的内核锁定 OS: $ID" >&2; exit 1
fi
printf '%s\n' "$kernel" > /etc/kubekey/rise/locked-kernel
printf '当前运行内核: %s\n' "$kernel"
if command -v grubby >/dev/null; then grubby --default-kernel; fi
if [ -f /etc/default/grub ]; then grep '^GRUB_DEFAULT=' /etc/default/grub || true; fi
echo '包锁定完成；启动项与重启后内核需在现场验证，不自动重启。'
