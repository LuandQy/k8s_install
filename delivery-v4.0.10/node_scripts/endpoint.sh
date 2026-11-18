#!/usr/bin/env bash
set -euo pipefail
address="$1"; port="$2"
timeout 8 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' bash "$address" "$port" || { printf '外部 API LB 不可达: %s:%s\n' "$address" "$port" >&2; exit 1; }
