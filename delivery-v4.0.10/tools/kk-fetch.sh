#!/usr/bin/env bash
# 获取并核对官方 KubeKey 二进制。供应商/开发工具，不属于部署流程。
# 交付默认随带 v4.0.10；切换版本必须同时核对摘要，并在需要时重新打包离线制品与重新验收。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$ROOT/lib/kk-binaries.sha256"
VERSION=''
ARCH_REQUEST=both
APPLY=false
RECORD=false
CHECK=false

usage() {
    cat <<'USAGE'
用法: ./tools/kk-fetch.sh --version v4.0.10 [--arch amd64|arm64|both] [--apply] [--record]
  --version   KubeKey 版本（如 v4.0.10），必须与官方 Release 标签一致
  --arch      默认 both，只处理指定架构
  --apply     摘要核对通过后替换 tools/<arch>/kk（保留 .bak；根目录不再生成 kk-amd/kk-arm）
  --record    摘要不在 lib/kk-binaries.sha256 时，把本次核对结果写入该表
  --check     只核对现有二进制与摘要表，不联网
说明: 该工具需要联网，仅用于供应商重制；离线部署现场不要执行。
USAGE
}
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
short_arch() { case "$1" in amd64) printf amd;; arm64) printf arm;; *) die "不支持的架构: $1";; esac; }
recorded_digest() { awk -v name="$1" -v ver="$2" '!/^#/ && $2==name && $3==ver {print $1; exit}' "$TABLE"; }

check_existing() {
    local short arch name digest expected missing=0
    for arch in amd64 arm64; do
        short=$(short_arch "$arch"); name="tools/$arch/kk"
        [ -f "$ROOT/$name" ] || { printf '缺失 %s\n' "$ROOT/$name"; missing=1; continue; }
        digest=$(sha256_file "$ROOT/$name")
        expected=$(recorded_digest "$name" "$VERSION")
        if [ -z "$expected" ]; then printf '未记录 %s %s 的摘要\n' "$name" "$VERSION"; missing=1
        elif [ "$digest" = "$expected" ]; then printf 'OK   %s %s %s\n' "$name" "$VERSION" "$digest"
        else printf '不符 %s %s 期望 %s 实际 %s\n' "$name" "$VERSION" "$expected" "$digest"; missing=1; fi
        if [ -f "$ROOT/tools/$arch/kk" ]; then
            [ "$(sha256_file "$ROOT/tools/$arch/kk")" = "$digest" ] || printf '提示: tools/%s/kk 与 %s 不一致\n' "$arch" "$name"
        fi
    done
    [ "$missing" -eq 0 ] || die '现有二进制与摘要表不一致；请用 --apply 重新安装或核对现场文件'
    printf '现有二进制与摘要表一致。\n'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2;;
        --arch) ARCH_REQUEST="${2:-}"; shift 2;;
        --apply) APPLY=true; shift;;
        --record) RECORD=true; shift;;
        --check) CHECK=true; shift;;
        -h|--help) usage; exit 0;;
        *) die "不支持的参数: $1（使用 --help）";;
    esac
done
[ -n "$VERSION" ] || { usage; exit 2; }
case "$VERSION" in v4.0.*) ;; *) die '版本必须以 v4.0. 开头，避免把非 4.0 发布混入交付';; esac
case "$ARCH_REQUEST" in amd64|arm64|both) ;; *) die '--arch 只接受 amd64/arm64/both';; esac
if [ "$CHECK" = true ]; then check_existing; exit 0; fi
case "$(uname -s)" in Linux|Darwin) ;; *) die '仅支持 Linux/macOS 下载端';; esac
command -v curl >/dev/null || die '需要 curl'
command -v tar >/dev/null || die '需要 tar'

arches=(amd64 arm64)
[ "$ARCH_REQUEST" = both ] || arches=("$ARCH_REQUEST")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kk-fetch.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
base="https://github.com/kubesphere/kubekey/releases/download/$VERSION"

# Digest hand-off between loops lives in temp files: associative arrays would
# require Bash 4, and this supplier tool may run on an older macOS shell too.
for arch in "${arches[@]}"; do
    short=$(short_arch "$arch")
    name="tools/$arch/kk"
    asset="kubekey-$VERSION-linux-$arch.tar.gz"
    printf '下载 %s\n' "$asset" >&2
    curl -fL --retry 3 --connect-timeout 20 --max-time 1800 -o "$tmp/$asset" "$base/$asset" ||
        die "下载失败: $base/$asset"
    mkdir -p "$tmp/$arch"
    tar -xzf "$tmp/$asset" -C "$tmp/$arch" ||
        die "解包失败: $asset"
    [ -f "$tmp/$arch/kk" ] || die "归档中没有 kk: $asset"
    digest=$(sha256_file "$tmp/$arch/kk")
    expected=$(recorded_digest "$name" "$VERSION")
    if [ -z "$expected" ]; then
        printf '新摘要 %s  %s  %s\n' "$digest" "$name" "$VERSION"
        if [ "$RECORD" != true ] && [ "$APPLY" != true ]; then
            die "摘要未记录；确认来源可信后用 --record 写入 lib/kk-binaries.sha256"
        fi
    elif [ "$digest" != "$expected" ]; then
        die "摘要不符: $name $VERSION 期望 $expected 实际 $digest"
    else
        printf '摘要一致 %s %s\n' "$name" "$VERSION"
    fi
    printf '%s\n' "$digest" > "$tmp/digest-$arch"
done

if [ "$APPLY" != true ] && [ "$RECORD" != true ]; then
    printf '\n未修改交付目录。使用 --apply 安装二进制，或 --record 仅记录摘要。\n'
    exit 0
fi
if [ "$RECORD" = true ] || [ "$APPLY" = true ]; then
    for arch in "${arches[@]}"; do
        short=$(short_arch "$arch"); name="tools/$arch/kk"; digest="$(cat "$tmp/digest-$arch")"
        if [ -z "$(recorded_digest "$name" "$VERSION")" ]; then
            printf '%s  %s  %s\n' "$digest" "$name" "$VERSION" >> "$TABLE"
            printf '已记录 %s %s\n' "$name" "$VERSION"
        fi
    done
fi
if [ "$APPLY" = true ]; then
    stamp=$(date +%Y%m%dT%H%M%S)
    for arch in "${arches[@]}"; do
        short=$(short_arch "$arch"); name="tools/$arch/kk"
        install -d -m 0755 "$ROOT/tools/$arch"
        [ ! -f "$ROOT/tools/$arch/kk" ] || cp -p "$ROOT/tools/$arch/kk" "$ROOT/tools/$arch/kk.bak.$stamp"
        install -m 0755 "$tmp/$arch/kk" "$ROOT/tools/$arch/kk"
        printf '已安装 %s（%s）\n' "$name" "$VERSION"
    done
    printf '\n下一步: 更新 cluster-vars.env 的 KK_VERSION=%s，并重新生成 SHA256SUMS/SOURCE_SHA256SUMS。\n' "$VERSION"
    printf '若切换为 v4.0.10，请按 docs/kubekey-4.0.10.md 评估离线制品与模板差异后再验收。\n'
fi
