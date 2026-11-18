#!/usr/bin/env bash
# Standalone export; relative paths are anchored to this script directory.
set -euo pipefail

if [ "$#" -gt 0 ]; then
    case "$1" in
        -h|--help)
            printf '%s\n' '用法: bash package.sh' \
                '在脚本同目录准备 package-config.yaml 以及本机架构对应的 tools/<arch>/kk。' \
                '默认输出至脚本同目录 artifact/；PACKAGE_WORK_DIR 可覆盖工作目录。'
            exit 0
            ;;
        *) printf '不支持的参数: %s，请使用 --help\n' "$1" >&2; exit 1 ;;
    esac
fi

fail() { printf '错误: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || fail 'KubeKey 打包需要在 Linux 上执行'
case "$(uname -m)" in
    x86_64|amd64) binary=tools/amd64/kk ;;
    aarch64|arm64) binary=tools/arm64/kk ;;
    *) fail "不支持的本机架构: $(uname -m)" ;;
esac

work_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
kk="$work_dir/$binary"
config="$work_dir/package-config.yaml"
[ -f "$kk" ] && [ -x "$kk" ] || fail "缺少可执行文件 ${kk}，请准备 tools/<arch>/kk 并执行 chmod +x $binary"
[ -f "$config" ] && [ -r "$config" ] || fail "缺少可读配置 $config"
printf '使用二进制: %s\n打包配置: %s\n' "$kk" "$config"
package_work_dir="${PACKAGE_WORK_DIR:-}"
if [ -z "$package_work_dir" ]; then
    package_work_dir=$(awk '$1=="work_dir:" {sub(/^[[:space:]]*work_dir:[[:space:]]*/,"");sub(/[[:space:]]+#.*/,"");gsub(/["\047]/,"");sub(/[[:space:]]*$/,"");print;exit}' "$config")
fi
package_work_dir="${package_work_dir:-$work_dir}"
case "$package_work_dir" in /*) ;; *) package_work_dir="$work_dir/$package_work_dir";; esac
mkdir -p "$package_work_dir"
package_work_dir="$(cd -- "$package_work_dir" && pwd -P)"
case "$package_work_dir" in /|/etc|/usr|/var|/var/lib) fail '拒绝将系统目录作为打包工作目录';; esac
printf '打包工作目录: %s\n' "$package_work_dir"
cd "$work_dir"
"$kk" artifact export --workdir "$package_work_dir" -c "$config"
artifact_dir="$package_work_dir/artifact"
[ -s "$artifact_dir/kubekey-artifact.tgz" ] || fail "缺少导出归档: $artifact_dir/kubekey-artifact.tgz"
# stage_tools requires this manifest for the external nerdctl archives.
(
    cd "$artifact_dir"
    find . -type f ! -name SHA256SUMS ! -name .SHA256SUMS.tmp -print | LC_ALL=C sort | while IFS= read -r file; do
        if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file"; else shasum -a 256 "$file"; fi
    done > .SHA256SUMS.tmp
    mv .SHA256SUMS.tmp SHA256SUMS
)
printf '制作完成: %s\n已生成产物 SHA256SUMS；请保留 artifact/ 下的全部文件。\n' "$artifact_dir"
