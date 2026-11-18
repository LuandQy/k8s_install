#!/usr/bin/env bash
# mode: preinstalled, online, iso, bootstrap; second arg ISO/archive/dir; need_nfs_server (0/1)
set -euo pipefail
mode="$1"; iso="${2:--}"; nfs_server="${3:-0}"
. /etc/os-release
arch="$(uname -m)"
case "$arch" in
    x86_64|amd64) arch=amd64;;
    aarch64|arm64) arch=aarch64;;
esac
test "$(id -u)" -eq 0
required=(socat conntrack ipset ebtables ipvsadm tar iptables mount.nfs chronyd chronyc busybox)
if [ "$nfs_server" = 1 ]; then required+=(exportfs); fi
missing=()
for c in "${required[@]}"; do command -v "$c" >/dev/null || missing+=("$c"); done
if [ "${#missing[@]}" -eq 0 ]; then echo '[OK] 依赖已预装'; exit 0; fi
if [ "$mode" = preinstalled ]; then echo "缺少依赖: ${missing[*]}" >&2; exit 1; fi
if [ "$mode" = bootstrap ]; then
    archive="$iso"
    if [ -d "$archive" ]; then
        token="$VERSION_CODENAME"
        [ -n "$token" ] || token="$ID$VERSION_ID"
        case "$ID:$VERSION_ID" in
            ubuntu:22.04) token=jammy;;
            ubuntu:24.04) token=noble;;
            kylin:10*) token=ky10;;
        esac
        case "$ID" in kylin|neokylin) token=ky10;; esac
        altarch="$arch"
        [ "$arch" != aarch64 ] || altarch=arm64
        found=''
        for candidate in "bootstrap-$token-$arch.tar.gz" "bootstrap-$token-$altarch.tar.gz"; do
            if [ -f "$archive/$candidate" ]; then archive="$archive/$candidate"; found=1; break; fi
        done
        [ -n "$found" ] || { echo "bootstrap/ 中没有匹配 $ID $VERSION_ID $arch 的离线包" >&2; exit 1; }
    fi
    test -f "$archive" || { echo "bootstrap 离线包不存在: $archive" >&2; exit 1; }
    tmp="$(mktemp -d /tmp/rise-bootstrap.XXXXXX)"
    trap 'rm -rf -- "$tmp"' EXIT
    tar -xzf "$archive" -C "$tmp"
    if [ -f "$tmp/SHA256SUMS" ]; then (cd "$tmp" && sha256sum -c SHA256SUMS); fi
    if [ "$ID" = ubuntu ]; then
        packages=(socat conntrack ipset ebtables ipvsadm tar iptables nfs-common chrony busybox-static)
        [ "$nfs_server" != 1 ] || packages+=(nfs-kernel-server)
        chmod 755 "$tmp"
        echo "deb [trusted=yes] file:$tmp /" > "$tmp/sources.list"
        opts=(-o "Dir::Etc::sourcelist=$tmp/sources.list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
        apt-get "${opts[@]}" update
        DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" install -y "${packages[@]}"
    else
        packages=(socat conntrack-tools ipset ebtables ipvsadm tar iptables nfs-utils chrony busybox)
        [ "$nfs_server" != 1 ] || packages+=(nfs-utils)
        if [ ! -d "$tmp/repodata" ]; then
            command -v createrepo_c >/dev/null || { echo 'bootstrap RPM 包缺少 repodata 且没有 createrepo_c' >&2; exit 1; }
            createrepo_c "$tmp"
        fi
        mgr=dnf
        command -v dnf >/dev/null || mgr=yum
        "$mgr" --disablerepo='*' --repofrompath=rise-bootstrap,file://"$tmp" --enablerepo=rise-bootstrap --nogpgcheck install -y "${packages[@]}"
    fi
    for c in "${required[@]}"; do command -v "$c" >/dev/null || { echo "缺少依赖: $c" >&2; exit 1; }; done
    echo '[OK] bootstrap 离线依赖安装完成'
    exit 0
fi
if [ "$ID" = ubuntu ]; then
    packages=(socat conntrack ipset ebtables ipvsadm tar iptables nfs-common chrony busybox-static)
    [ "$nfs_server" != 1 ] || packages+=(nfs-kernel-server)
elif [ "$ID" = kylin ] || [ "$ID" = '"kylin"' ]; then
    packages=(socat conntrack-tools ipset ebtables ipvsadm tar iptables nfs-utils chrony busybox)
else
    echo "不支持的 OS: $ID" >&2; exit 1
fi
tmp="$(mktemp -d /tmp/rise-deps.XXXXXX)"
cleanup() {
    local original_rc=$? cleanup_rc
    trap - EXIT
    if mountpoint -q "$tmp/repo"; then
        if umount "$tmp/repo"; then :; else
            cleanup_rc=$?
            printf '[ERROR] 离线依赖 ISO 卸载失败（退出码 %s）；保留临时目录，不删除挂载内容：%s\n' "$cleanup_rc" "$tmp" >&2
            [ "$original_rc" -ne 0 ] || original_rc="$cleanup_rc"
            exit "$original_rc"
        fi
    fi
    if rm -rf -- "$tmp"; then :; else
        cleanup_rc=$?
        printf '[ERROR] 离线依赖临时目录清理失败（退出码 %s）：%s\n' "$cleanup_rc" "$tmp" >&2
        [ "$original_rc" -ne 0 ] || original_rc="$cleanup_rc"
    fi
    exit "$original_rc"
}
trap cleanup EXIT
if [ "$mode" = iso ]; then
    test -f "$iso" || { echo '缺少离线依赖 ISO，禁止回退外网' >&2; exit 1; }
    mkdir "$tmp/repo"
    mount -o loop,ro "$iso" "$tmp/repo"
    if [ "$ID" = ubuntu ]; then
        chmod 755 "$tmp"
        echo "deb [trusted=yes] file:$tmp/repo /" > "$tmp/sources.list"
        opts=(-o "Dir::Etc::sourcelist=$tmp/sources.list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
        apt-get "${opts[@]}" update
        DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" install -y "${packages[@]}"
    else
        yum --disablerepo='*' --repofrompath="rise-offline,file://$tmp/repo" --enablerepo=rise-offline --nogpgcheck install -y "${packages[@]}"
    fi
elif [ "$mode" = online ]; then
    if [ "$ID" = ubuntu ]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    else
        yum install -y "${packages[@]}"
    fi
else
    echo '依赖模式无效' >&2; exit 1
fi
for c in "${required[@]}"; do command -v "$c" >/dev/null || { echo "缺少依赖: $c" >&2; exit 1; }; done
