#!/usr/bin/env bash
# Refresh artifact/SHA256SUMS only; use tools/refresh-checksums.sh for the outer tree.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
artifact="$root/artifact"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --artifact-dir) artifact="${2:-}"; shift 2;;
        -h|--help)
            printf '%s\n' '用法: tools/artifact-refresh.sh [--artifact-dir 目录]'
            printf '%s\n' '校验 artifact 下的 kubekey-artifact.tgz/manifests.yaml 并重写 SHA256SUMS。'
            exit 0;;
        *) printf '不支持的参数: %s\n' "$1" >&2; exit 2;;
    esac
done
[ -d "$artifact" ] || { echo "artifact 目录不存在: $artifact" >&2; exit 1; }
[ -s "$artifact/kubekey-artifact.tgz" ] || { echo '缺少 artifact/kubekey-artifact.tgz' >&2; exit 1; }
[ -s "$artifact/manifests.yaml" ] || { echo '缺少 artifact/manifests.yaml' >&2; exit 1; }
cd "$artifact"
find . -type f ! -name SHA256SUMS ! -name .SHA256SUMS.tmp -print | LC_ALL=C sort | while IFS= read -r file; do
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file"; else shasum -a 256 "$file"; fi
done > .SHA256SUMS.tmp
mv .SHA256SUMS.tmp SHA256SUMS
printf '[OK] 已刷新 %s/SHA256SUMS（%s 项）\n' "$artifact" "$(wc -l < SHA256SUMS | tr -d ' ')"
printf '下一步: 运行 lib/offline-audit.py 校验版本/架构，再运行 tools/refresh-checksums.sh 刷新外层清单。\n'
