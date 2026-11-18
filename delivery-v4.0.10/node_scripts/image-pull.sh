#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
command -v crictl >/dev/null
command -v timeout >/dev/null
ref="$1"
# No docker, no insecure flags, no cache deletion. Respect installed CRI config.
test -r /etc/crictl.yaml
timeout 180 crictl --config /etc/crictl.yaml pull "$ref" >&2
timeout 30 crictl --config /etc/crictl.yaml inspecti "$ref"
