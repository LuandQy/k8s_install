#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ "$#" -ne 3 ]; then
    echo '用法：./deploy-native.sh precheck|install INVENTORY CONFIG' >&2
    exit 2
fi
case "$1" in
    precheck) playbook=precheck.yaml ;;
    install) playbook=create_cluster.yaml ;;
    *) echo '支持 precheck 和 install' >&2; exit 2 ;;
esac
case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) echo '控制端架构不受支持' >&2; exit 1 ;;
esac
test -r "$2" && test -r "$3"
umask 077
exec "$root/tools/$arch/kk" run "playbooks/$playbook" \
    --project-addr "$root/kk-project" -i "$2" -c "$3" \
    -a "$root/artifact/kubekey-artifact.tgz" \
    --workdir "${KK_WORKDIR:-$root/run}"
