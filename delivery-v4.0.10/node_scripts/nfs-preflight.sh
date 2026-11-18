#!/usr/bin/env bash
# Read-only gate used after the independent deps stage.
set -euo pipefail
if ! command -v exportfs >/dev/null 2>&1; then
    echo '[ERROR] NFS 服务端依赖缺失：请通过 deploy.sh deps 从匹配离线介质安装 Ubuntu nfs-kernel-server / Kylin nfs-utils；缺包时先补齐离线介质，禁止回退外网。' >&2
    exit 1
fi
echo '[OK] NFS exportfs 已存在；服务配置和挂载读写由 services-init/services-verify 验收，PVC 仍需实机验证。'
