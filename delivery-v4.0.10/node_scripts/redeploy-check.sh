#!/usr/bin/env bash
set -euo pipefail
roles=",$1,"
fail() { printf '[ERROR] 重新部署检查: %s\n' "$*" >&2; exit 1; }
! systemctl is-active --quiet kubelet || fail 'kubelet 仍运行'
[ ! -s /etc/kubernetes/admin.conf ] || fail '已有 Kubernetes 配置'
if [[ "$roles" = *,etcd,* ]]; then
    ! systemctl is-active --quiet etcd || fail 'etcd 仍运行'
    if [ -d /var/lib/etcd ]; then [ -z "$(ls -A /var/lib/etcd)" ] || fail 'etcd 数据未清空'; fi
fi
if [[ "$roles" = *,registry,* ]]; then systemctl is-active --quiet harbor || fail '保留的 Harbor 未运行'; fi
printf '[OK] 重置后的节点可重新部署\n'
