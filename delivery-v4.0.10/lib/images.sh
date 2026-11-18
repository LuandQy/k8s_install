#!/usr/bin/env bash
# Image list generation. Every version comes from the version-specific project
# defaults; an unparsable template must stop here instead of producing "image:"
# with an empty tag that only fails much later in the registry check.
# Helpers return non-zero so callers can fail closed even inside substitutions.
image_default_tag() {
    local file value
    file="$(artifact_vars_file)"
    [ -f "$file" ] || { printf '[ERROR] 缺少 %s 的组件版本文件：%s\n' "${KUBE_VERSION:-未设置}" "$file" >&2; return 1; }
    value=$(awk -v section="$1:" '$1==section {on=1;next} on && $1=="tag:" {gsub(/["\047]/,"",$2);print $2;exit}' "$file")
    [ -n "$value" ] || { printf '[ERROR] 无法从 %s 解析镜像标签 %s；版本模板格式可能已变更\n' "$file" "$1" >&2; return 1; }
    printf '%s\n' "$value"
}
selected_target_images() {
    local calico pause dns nodecache
    artifact_vars_check || return 1
    calico=$(artifact_default calico_version) || return 1
    pause=$(image_default_tag sandbox_image) || return 1
    dns=$(image_default_tag coredns) || return 1
    nodecache=$(image_default_tag nodelocaldns) || return 1
    {
        for image in kube-apiserver kube-controller-manager kube-scheduler kube-proxy; do printf 'registry.k8s.io/%s:%s\n' "$image" "$KUBE_VERSION"; done
        printf 'registry.k8s.io/pause:%s\nregistry.k8s.io/coredns/coredns:%s\nregistry.k8s.io/dns/k8s-dns-node-cache:%s\n' "$pause" "$dns" "$nodecache"
        if [ "$ENDPOINT_TYPE" = kube-vip ]; then printf 'docker.io/plndr/kube-vip:v0.7.2\n'; fi
        jq -r --arg version "$calico" '.[$version][]' "$ROOT/lib/calico-images.json" || return 1
        # cluster-verify also needs an offline diagnostic Pod when PVC testing
        # is disabled. Keep this image in the explicit import/verification list.
        printf 'docker.io/openebs/linux-utils:4.3.0\n'
        [ "$LOCAL_STORAGE" != true ] || printf 'docker.io/openebs/provisioner-localpv:4.4.0\n'
        [ "$NFS_MODE" = none ] || printf 'registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2\n'
    } | jq -Rsc 'split("\n")|map(select(length>0))|unique'
}
