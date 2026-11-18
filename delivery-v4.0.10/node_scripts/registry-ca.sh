#!/usr/bin/env bash
# Install the managed Harbor CA for CRI clients. Parameters: domain.
set -euo pipefail
domain="${1:?domain required}"
src=/etc/kubekey/rise/harbor-ca.pem
[ -s "$src" ] || { echo '[ERROR] Harbor CA upload missing' >&2; exit 1; }
install -d -m 755 "/etc/containerd/certs.d/$domain"
install -m 644 "$src" "/etc/containerd/certs.d/$domain/ca.crt"
install -d -m 755 "/etc/docker/certs.d/$domain"
install -m 644 "$src" "/etc/docker/certs.d/$domain/ca.crt"
echo "[OK] Harbor CA synced for $domain"
