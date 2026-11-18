#!/usr/bin/env bash
# Atomically add the cluster-owned /etc/hosts block. Parameters: newline block.
set -euo pipefail
block="$1"
marker='# rise-deploy cluster'
[ -n "$block" ] || { echo '[ERROR] hosts block is empty' >&2; exit 1; }
tmp="$(mktemp /etc/hosts.rise.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
# Preserve unrelated entries and reject unmarked conflicting names.
awk -v marker="$marker" '
  index($0, marker) {next}
  {print}
' /etc/hosts > "$tmp"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    ip="${line%% *}"
    name="${line#* }"
    if awk -v name="$name" -v ip="$ip" -v marker="$marker" '
      index($0, marker) {next}
      {for (i=2;i<=NF;i++) if ($i==name && $1!=ip) bad=1}
      END {exit !bad}
    ' /etc/hosts; then
        echo "[ERROR] /etc/hosts 已有冲突映射: $name -> $ip" >&2
        exit 1
    fi
done <<< "$block"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s %s\n' "$line" "$marker" >> "$tmp"
done <<< "$block"
chmod 644 "$tmp"
cat "$tmp" > /etc/hosts
echo '[OK] /etc/hosts cluster block updated'
