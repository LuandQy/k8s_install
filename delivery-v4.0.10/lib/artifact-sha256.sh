#!/usr/bin/env bash
# CLI parity for the Web artifact SHA control; local trusted operator only.
set -euo pipefail
file=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --file) file="$2"; shift 2;;
        -h|--help)
            printf '%s\n' '用法: deploy.sh artifact-sha256 --file /absolute/path/archive.tgz'
            printf '%s\n' '流式计算本地归档摘要；不读取配置、不连接节点、不写入草稿。'
            exit 0;;
        *) printf '不支持的参数: %s\n' "$1" >&2; exit 2;;
    esac
done
[ -n "$file" ] || { printf '%s\n' '缺少 --file 绝对路径' >&2; exit 2; }
case "$file" in /*) ;; *) printf '%s\n' '归档路径必须为绝对路径' >&2; exit 2;; esac
[ -f "$file" ] && [ -r "$file" ] || { printf '归档不存在或不可读: %s\n' "$file" >&2; exit 1; }
dir=$(cd -- "$(dirname -- "$file")" && pwd -P)
file="$dir/$(basename -- "$file")"
if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" | awk '{print $1}')
else
    digest=$(shasum -a 256 "$file" | awk '{print $1}')
fi
size=$(wc -c < "$file" | tr -d ' ')
printf 'path=%s\nsha256=%s\nbytes=%s\n' "$file" "$digest" "$size"
