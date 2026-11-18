#!/usr/bin/env bash
# Read scalar versions from the version-specific project defaults (not arbitrary YAML).
# These helpers return non-zero instead of exiting: callers frequently run them in
# command substitutions and conditionals, where "set -e" does not propagate a
# subshell failure. An unparsable template must never yield an empty requirement
# list that silently passes the offline archive check.
ARTIFACT_VERSION_KEYS='containerd_version runc_version crictl_version etcd_version helm_version cni_plugins_version calico_version harbor_version docker_version dockercompose_version keepalived_version localpv_provisioner_version nfs_provisioner_version'

artifact_vars_file() {
    printf '%s/kk-project/roles/defaults/vars/%s.yaml\n' "$ROOT" "${KUBE_VERSION%.*}"
}

artifact_default() {
    local file key="$1" value
    file="$(artifact_vars_file)"
    [ -f "$file" ] || { printf '[ERROR] 缺少 %s 的组件版本文件：%s\n' "${KUBE_VERSION:-未设置}" "$file" >&2; return 1; }
    value=$(awk -v key="$key:" '$1==key {gsub(/["\047]/,"",$2);print $2;exit}' "$file")
    [ -n "$value" ] || { printf '[ERROR] 无法从 %s 解析 %s；版本模板格式可能已变更\n' "$file" "$key" >&2; return 1; }
    printf '%s\n' "$value"
}

artifact_vars_check() {
    local file key value missing=''
    file="$(artifact_vars_file)"
    [ -f "$file" ] || { printf '[ERROR] 缺少 %s 的组件版本文件：%s\n' "${KUBE_VERSION:-未设置}" "$file" >&2; return 1; }
    for key in $ARTIFACT_VERSION_KEYS; do
        value=$(awk -v key="$key:" '$1==key {gsub(/["\047]/,"",$2);print $2;exit}' "$file")
        [ -n "$value" ] || missing="$missing $key"
    done
    [ -z "$missing" ] || { printf '[ERROR] 版本文件 %s 缺少字段:%s；不能生成离线包必需成员清单\n' "$file" "$missing" >&2; return 1; }
}

artifact_required_members() {
    local v a="$NODE_ARCH" calico
    artifact_vars_check || return 1
    if [ "${COMPONENTS:-all}" != harbor ]; then
    for v in kubelet kubeadm kubectl; do printf 'kube/%s/%s/%s\n' "$KUBE_VERSION" "$a" "$v"; done
    v=$(artifact_default containerd_version) || return 1; printf 'containerd/%s/%s/containerd-%s-linux-%s.tar.gz\n' "$v" "$a" "${v#v}" "$a"
    v=$(artifact_default runc_version) || return 1; printf 'runc/%s/%s/runc.%s\n' "$v" "$a" "$a"
    v=$(artifact_default crictl_version) || return 1; printf 'crictl/%s/%s/crictl-%s-linux-%s.tar.gz\n' "$v" "$a" "$v" "$a"
    v=$(artifact_default etcd_version) || return 1; printf 'etcd/%s/%s/etcd-%s-linux-%s.tar.gz\n' "$v" "$a" "$v" "$a"
    v=$(artifact_default helm_version) || return 1; printf 'helm/%s/%s/helm-%s-linux-%s.tar.gz\n' "$v" "$a" "$v" "$a"
    v=$(artifact_default cni_plugins_version) || return 1; printf 'cni/plugins/%s/%s/cni-plugins-linux-%s-%s.tgz\n' "$v" "$a" "$a" "$v"
    calico=$(artifact_default calico_version) || return 1
    printf 'cni/calico/%s/%s/calicoctl-linux-%s\n' "$calico" "$a" "$a"
    printf 'cni/calico/tigera-operator-%s.tgz\n' "$calico"
    [ "$calico" != v3.32.2 ] || printf 'cni/calico/crd.projectcalico.org.v1-%s.tgz\n' "$calico"
    fi
    if has_role registry && [ "${COMPONENTS:-all}" != k8s ]; then
        v=$(artifact_default harbor_version) || return 1; printf 'image-registry/harbor/%s/%s/harbor-offline-installer-%s.tgz\n' "$v" "$a" "$v"
        v=$(artifact_default docker_version) || return 1; printf 'docker/%s/%s/docker-%s.tgz\n' "$v" "$a" "$v"
        v=$(artifact_default dockercompose_version) || return 1; printf 'image-registry/docker-compose/%s/%s/docker-compose\n' "$v" "$a"
        v=$(artifact_default keepalived_version) || return 1; printf 'image-registry/keepalived/%s/%s/keepalived-%s-linux-%s.tgz\n' "$v" "$a" "$v" "$a"
    fi
    [ "${COMPONENTS:-all}" != harbor ] || return 0
    if [ "$LOCAL_STORAGE" = true ]; then v=$(artifact_default localpv_provisioner_version) || return 1; printf 'storageclass/local/localpv-provisioner-%s.tgz\n' "$v"; fi
    if [ "$NFS_MODE" != none ]; then v=$(artifact_default nfs_provisioner_version) || return 1; printf 'storageclass/nfs/nfs-subdir-external-provisioner-%s.tgz\n' "$v"; fi
}
