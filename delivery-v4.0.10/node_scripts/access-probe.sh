#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test "$(uname -s)" = Linux
cat /etc/machine-id
if [ -r /sys/class/dmi/id/product_uuid ]; then cat /sys/class/dmi/id/product_uuid; else printf '\n'; fi
hostname
