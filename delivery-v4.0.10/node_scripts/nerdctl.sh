#!/usr/bin/env sh
# Idempotent nerdctl pre-installation and /etc/nerdctl/nerdctl.toml setup for K8s nodes.
set -eu

archive="${1:-}"
expected_arch="${2:-}"
dest_root="${NERDCTL_DEST_ROOT:-}"
raw_arch="${NERDCTL_TEST_UNAME_M:-$(uname -m)}"

case "$raw_arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)
        echo "[ERROR] 不支持的节点架构: $raw_arch" >&2
        exit 1
        ;;
esac

if [ -n "$expected_arch" ] && [ "$arch" != "$expected_arch" ]; then
    echo "[ERROR] 节点实际架构 ($arch) 与声明架构 ($expected_arch) 架构不匹配" >&2
    exit 1
fi

bin_dir="${dest_root}/usr/local/bin"
conf_dir="${dest_root}/etc/nerdctl"
conf_file="${conf_dir}/nerdctl.toml"

installed=0
if [ -z "$dest_root" ]; then
    if command -v nerdctl >/dev/null 2>&1 || [ -x /usr/local/bin/nerdctl ]; then
        installed=1
    fi
else
    if [ -x "${bin_dir}/nerdctl" ]; then
        installed=1
    fi
fi

if [ "$installed" -eq 0 ]; then
    if [ -z "$archive" ]; then
        script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
        for candidate in \
            "${script_dir}/nerdctl-2.2.1-linux-${arch}.tar.gz" \
            "${script_dir}/../artifact/tools/${arch}/nerdctl-2.2.1-linux-${arch}.tar.gz"; do
            if [ -f "$candidate" ]; then
                archive="$candidate"
                break
            fi
        done
    fi
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        echo "[ERROR] 未找到 nerdctl 离线归档: ${archive:-nerdctl-2.2.1-linux-${arch}.tar.gz}" >&2
        exit 1
    fi
    mkdir -p "$bin_dir"
    tar --no-same-owner -xzf "$archive" -C "$bin_dir"
    chmod 0755 "${bin_dir}/nerdctl"
fi

if [ "$archive" = "/etc/kubekey/rise/nerdctl.tar.gz" ] && [ -z "$dest_root" ]; then
    rm -f "$archive"
fi

if [ ! -f "$conf_file" ]; then
    mkdir -p "$conf_dir"
    chmod 0755 "$conf_dir"
    cat <<'EOF' > "$conf_file"
namespace      = "k8s.io"
cgroup_manager = "cgroupfs"
hosts_dir      = ["/etc/containerd/certs.d", "/etc/docker/certs.d"]
EOF
    chmod 0644 "$conf_file"
fi

echo "[OK] nerdctl (${arch}) 与 ${conf_file} 已就绪"
