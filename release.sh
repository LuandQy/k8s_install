#!/usr/bin/env bash
# Unified release hygiene, regression test, and manifest refresh script.
# Usage: bash release.sh [--skip-http-tests] [--pack <output.tar.gz>]
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PKG_DIR="$ROOT_DIR/delivery-v4.0.10"
SKIP_HTTP=false
PACK_OUT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-http-tests) SKIP_HTTP=true; shift ;;
        --pack) PACK_OUT="${2:?--pack 需要输出文件名}"; shift 2 ;;
        -h|--help)
            printf '用法: bash release.sh [--skip-http-tests] [--pack delivery-v4.0.10-YYYYMMDD.tar.gz]\n'
            exit 0
            ;;
        *)
            printf '[ERROR] 未知参数: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

clean_ephemeral() {
    find "$ROOT_DIR" \( -name '__pycache__' -o -name '.pytest_cache' -o -name '.test-tmp' \) -prune -exec rm -rf {} + 2>/dev/null || true
    find "$ROOT_DIR" \( -name '*.pyc' -o -name '*.pyo' -o -name '._*' -o -name '.DS_Store' \) -type f -delete 2>/dev/null || true
}

printf '==> [1/5] 清理临时字节码与系统资源文件...\n'
clean_ephemeral

printf '==> [2/5] 执行全量 Shell 脚本语法检查...\n'
while IFS= read -r sh_file; do
    case "$sh_file" in
        */node_scripts/nerdctl.sh) sh -n "$sh_file" ;;
        *) bash -n "$sh_file" ;;
    esac
done < <(find "$PKG_DIR" "$ROOT_DIR/manage_lima_cluster.sh" "$ROOT_DIR/release.sh" -not -path '*/kk-project/*' -name '*.sh' -type f | LC_ALL=C sort)

printf '==> [3/5] 执行前端纯逻辑单测与 Python 回归测试...\n'
if command -v node >/dev/null 2>&1; then
    node "$PKG_DIR/tests/workbench-logic.test.js"
fi
export PYTHONDONTWRITEBYTECODE=1
export NO_PROXY="127.0.0.1,localhost"
export no_proxy="127.0.0.1,localhost"
if [ "$SKIP_HTTP" = true ]; then
    for test_file in "$PKG_DIR"/tests/test_*.py; do
        [ "$(basename "$test_file")" = "test_server.py" ] && continue
        python3 -B -m unittest discover -s "$PKG_DIR/tests" -p "$(basename "$test_file")"
    done
else
    python3 -B -m unittest discover -s "$PKG_DIR/tests" -p 'test_*.py'
fi
clean_ephemeral

printf '==> [4/5] 重新生成并核验交付包摘要清单 (SOURCE_SHA256SUMS / SHA256SUMS)...\n'
bash "$PKG_DIR/tools/refresh-checksums.sh"
(
    cd "$PKG_DIR"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c SOURCE_SHA256SUMS >/dev/null
        (cd artifact && sha256sum -c SHA256SUMS >/dev/null)
    else
        shasum -a 256 -c SOURCE_SHA256SUMS >/dev/null
        (cd artifact && shasum -a 256 -c SHA256SUMS >/dev/null)
    fi
)
printf '    [OK] SOURCE_SHA256SUMS 与 artifact/SHA256SUMS 校验全部通过\n'

if [ -n "$PACK_OUT" ]; then
    printf '==> [5/5] 正在生成外层交付归档: %s ...\n' "$PACK_OUT"
    (
        cd "$ROOT_DIR"
        COPYFILE_DISABLE=1 tar -czf "$PACK_OUT" delivery-v4.0.10
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$(basename "$PACK_OUT")" > "${PACK_OUT}.sha256"
        else
            shasum -a 256 "$(basename "$PACK_OUT")" > "${PACK_OUT}.sha256"
        fi
    )
    printf '    [OK] 已生成 %s 及 %s.sha256\n' "$PACK_OUT" "$PACK_OUT"
else
    printf '==> [5/5] 未指定 --pack，跳过 6.7GB 外层归档重打包。\n'
fi

printf '==> [SUCCESS] 发布前检查与摘要同步全部完成！\n'
