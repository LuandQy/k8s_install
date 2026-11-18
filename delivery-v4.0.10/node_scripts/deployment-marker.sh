#!/usr/bin/env bash
set -euo pipefail
action="$1"; token="$2"; dir=/etc/kubekey/rise
namespace="${3:-cluster}"
case "$namespace" in cluster) marker=deployment-id;; harbor) marker=harbor-deployment-id;; *) exit 1;; esac
[[ "$token" =~ ^[a-zA-Z0-9-]+$ ]] || exit 1
[ ! -L "$dir" ] && [ ! -L "$dir/$marker" ] || exit 1
case "$action" in
    create)
        mkdir -p "$dir"
        if [ -e "$dir/$marker" ]; then
            if [ "$(cat "$dir/$marker")" != "$token" ]; then
                printf '已有其他部署标记，拒绝覆盖: %s\n' "$dir/$marker" >&2
                exit 1
            fi
        else
            (umask 077; set -o noclobber; printf '%s\n' "$token" > "$dir/$marker")
        fi;;
    verify) [ "$(cat "$dir/$marker")" = "$token" ];;
    *) exit 1;;
esac
