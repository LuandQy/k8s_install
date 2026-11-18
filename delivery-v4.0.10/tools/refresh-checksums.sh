#!/usr/bin/env bash
# 供应商工具：重算交付摘要清单（SHA256SUMS / SOURCE_SHA256SUMS）。
# 只在打包前、清理完 ${._*} 与测试目录后执行；接收方不应重算后继续使用旧外部分发记录。
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
[ -z "$(find . -name '._*' -print -quit)" ] || fail '存在 macOS ._ 资源文件；先清理再重算'
[ -z "$(find . -name '__pycache__' -print -quit)" ] || fail '存在 __pycache__；先清理再重算'
[ ! -e .test-tmp ] || fail '存在 .test-tmp 测试目录；先清理再重算'

source_list() {
    find . -type f \
        ! -path './tests/*' ! -path './artifact/*' \
        ! -path './bootstrap/bootstrap-*.tar.gz' \
        ! -path './bootstrap/bootstrap-*.sha256' \
        ! -path './.test-tmp/*' ! -path './SHA256SUMS' ! -path './SOURCE_SHA256SUMS' ! -name '._*' \
        ! -path './tools/amd64/jq' ! -path './tools/arm64/jq' \
        ! -path './tools/amd64/kk' ! -path './tools/arm64/kk' \
        -print | sed 's|^\./||' | LC_ALL=C sort
}
all_list() {
    find . -type f ! -path './.test-tmp/*' ! -path './SHA256SUMS' ! -name '._*' \
        -print | sed 's|^\./||' | LC_ALL=C sort
}
write_manifest() {
    local file
    while IFS= read -r file; do
        printf '%s  ./%s\n' "$(hash_file "$file")" "$file"
    done
}
# SOURCE first: SHA256SUMS covers the final SOURCE_SHA256SUMS bytes.
source_list | write_manifest > SOURCE_SHA256SUMS
all_list | write_manifest > SHA256SUMS
printf 'SOURCE_SHA256SUMS: %s 条\nSHA256SUMS: %s 条\n' \
    "$(wc -l < SOURCE_SHA256SUMS | tr -d ' ')" "$(wc -l < SHA256SUMS | tr -d ' ')"
