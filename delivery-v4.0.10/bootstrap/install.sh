#!/usr/bin/env bash
# Install controller-side offline bootstrap packages for the detected OS/arch.
# Naming contract: bootstrap-<distro>-<arch>.tar.gz (+ .sha256).
set -euo pipefail
with_sshpass=false
case "$#" in
    0) ;;
    1)
        case "$1" in
            -h|--help)
                printf '%s\n' '用法: bash deploy.sh bootstrap [--with-sshpass]' \
                    '按 /etc/os-release 与 uname -m 自动匹配 bootstrap/bootstrap-<distro>-<arch>.tar.gz。' \
                    '支持 Ubuntu (apt) 与 Kylin (yum/dnf)；不安装 K8s/Harbor，不初始化节点或磁盘。'
                exit 0;;
            --with-sshpass) with_sshpass=true;;
            *) printf '不支持的 bootstrap 参数，请使用 --help\n' >&2; exit 2;;
        esac;;
    *) printf '不支持的 bootstrap 参数，请使用 --help\n' >&2; exit 2;;
esac
root=$(cd -- "$(dirname -- "$0")" && pwd)
. /etc/os-release
[ "$(id -u)" = 0 ] || { echo '需要 root。' >&2; exit 1; }
machine=$(uname -m)
case "$machine" in
    x86_64|amd64) arch=amd64; alt=amd64;;
    aarch64|arm64) arch=aarch64; alt=arm64;;
    *) echo "不支持的架构: $machine" >&2; exit 1;;
esac
token="$VERSION_CODENAME"
if [ -z "$token" ]; then
    case "$ID:$VERSION_ID" in
        ubuntu:22.04) token=jammy;;
        ubuntu:24.04) token=noble;;
        kylin:10*) token=ky10;;
        *) token="$ID$VERSION_ID";;
    esac
fi
case "$ID" in
    kylin|neokylin) token=ky10;;
esac
selected=''
for candidate in "bootstrap-$token-$arch.tar.gz" "bootstrap-$token-$alt.tar.gz"; do
    if [ -f "$root/$candidate" ]; then selected="$root/$candidate"; break; fi
done
[ -n "$selected" ] || { echo "bootstrap/ 中没有匹配 $ID $VERSION_ID $machine 的离线包；期望 bootstrap-$token-$arch.tar.gz" >&2; exit 1; }
checksum="$selected.sha256"
[ -f "$checksum" ] || { echo "缺少校验文件: $checksum" >&2; exit 1; }
(cd "$root" && sha256sum -c "$(basename "$checksum")")
tmp=$(mktemp -d /tmp/rise-bootstrap.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
tar -xzf "$selected" -C "$tmp"
[ ! -f "$tmp/SHA256SUMS" ] || (cd "$tmp" && sha256sum -c SHA256SUMS)
if [ "$ID" = ubuntu ]; then
    chmod 755 "$tmp"
    echo "deb [trusted=yes] file:$tmp /" > "$tmp/sources.list"
    opts=(-o "Dir::Etc::sourcelist=$tmp/sources.list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
    packages='jq util-linux openssh-client'
    [ "$with_sshpass" = false ] || packages="$packages sshpass"
    apt-get "${opts[@]}" update
    DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" install -y $packages
else
    packages='jq util-linux openssh-clients'
    [ "$with_sshpass" = false ] || packages="$packages sshpass"
    if [ ! -d "$tmp/repodata" ]; then
        command -v createrepo_c >/dev/null || { echo 'bootstrap RPM 包缺少 repodata 且未安装 createrepo_c' >&2; exit 1; }
        createrepo_c "$tmp"
    fi
    mgr=dnf
    command -v dnf >/dev/null || mgr=yum
    "$mgr" --disablerepo='*' --repofrompath=rise-bootstrap,file://"$tmp" --enablerepo=rise-bootstrap --nogpgcheck install -y $packages
fi
printf '[OK] bootstrap 安装完成: %s\n' "$(basename "$selected")"
