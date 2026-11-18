#!/usr/bin/env bash
. "$ROOT/lib/artifact-requirements.sh"
preflight_artifact() {
    [ "$DEPS_MODE" != iso ] || [ -n "$ARTIFACT_FILE" ] || die 'ISO 依赖模式需要离线包，未执行初始化'
    if [ -n "$ARTIFACT_FILE" ]; then
        verify_artifact
        stage_tools
    fi
}
verify_artifact() {
    [ -f "$ARTIFACT_FILE" ] || die '离线包不存在'
    [[ "$ARTIFACT_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || die '离线部署必须填写 ARTIFACT_SHA256'
    [ "$(sha256_file "$ARTIFACT_FILE")" = "$(printf '%s' "$ARTIFACT_SHA256" | tr A-F a-f)" ] || die '离线包 SHA256 不匹配'
    # Never derive an empty requirement list: an unparsable version template would
    # otherwise turn the member check below into a no-op.
    artifact_vars_check || die '组件版本文件不完整；不能生成离线包必需成员清单'
    # Capture the generator's exit status: a process substitution would hide a
    # partial list if the version template changed.
    artifact_required_members > "$RUN_DIR/artifact-required.txt" ||
        die '无法生成离线包必需成员清单；请核对版本模板与组件范围'
    mapfile -t required_members < "$RUN_DIR/artifact-required.txt"
    [ "${#required_members[@]}" -gt 0 ] || die '离线包必需成员清单为空；请核对版本模板与组件范围'
    tar -tzf "$ARTIFACT_FILE" > "$RUN_DIR/archive-names.txt"
    local member line
    while IFS= read -r member; do
        case "$member" in /*|../*|*/../*|*/..) die '归档包含不安全路径';; esac
    done < "$RUN_DIR/archive-names.txt"
    tar -tvzf "$ARTIFACT_FILE" > "$RUN_DIR/archive-types.txt"
    if grep -Eq '^[^d-]' "$RUN_DIR/archive-types.txt"; then die '归档含链接或特殊设备，拒绝自动解压'; fi
    sed 's@^\./@@' "$RUN_DIR/archive-names.txt" > "$RUN_DIR/archive-index.txt"
    grep -qx manifests.yaml "$RUN_DIR/archive-index.txt" || die '归档缺少 manifests.yaml'
    while IFS= read -r line; do
        parse_node "$line"
        local missing=0
        for member in "${required_members[@]}"; do
            if ! grep -Fxq "$member" "$RUN_DIR/archive-index.txt"; then
                printf '[ERROR] 离线依赖缺失: %s\n' "$member" >&2; missing=1
            fi
        done
        [ "$missing" -eq 0 ] || die "离线包不满足 $KUBE_VERSION/${NODE_ARCH}，未执行安装；请重新制作完整离线包"
        if [ "$DEPS_MODE" = iso ]; then
            grep -qx "repository/$NODE_OS-$NODE_ARCH.iso" "$RUN_DIR/archive-index.txt" || die "缺少 $NODE_OS-$NODE_ARCH.iso"
        fi
    done < <(active_node_lines)
}
stage_iso() {
    local member="repository/$NODE_OS-$NODE_ARCH.iso" cache="$WORK_DIR/iso-cache/$ARTIFACT_SHA256"
    mkdir -p "$cache"
    if [ ! -f "$cache/$member" ]; then
        local archived
        archived="$(awk -v wanted="$member" '{v=$0;sub(/^\.\//,"",v);if(v==wanted) print $0}' "$RUN_DIR/archive-names.txt")"
        [ -n "$archived" ] || die "缺少依赖 ISO: $member"
        tar -xzf "$ARTIFACT_FILE" -C "$cache" -- "$archived"
    fi
    ISO_FILE="$cache/$member"
}
elf_arch() {
    [ "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" = 7f454c46 ] || die "不是 Linux ELF: $1"
    local machine
    machine="$(od -An -tu2 -j18 -N2 "$1" | tr -d ' \n')"
    case "$2:$machine" in amd64:62|arm64:183) ;; *) die "ELF 架构不匹配: $1";; esac
}
resolve_nerdctl_archive() {
    local arch="$1" filename tools_base archive expected
    filename="nerdctl-2.2.1-linux-$arch.tar.gz"
    if [ -n "${ARTIFACT_FILE:-}" ]; then
        tools_base="$(cd "$(dirname "$ARTIFACT_FILE")" && pwd)"
    else
        tools_base="$ROOT/artifact"
    fi
    archive="$tools_base/tools/$arch/$filename"
    if [ -f "$archive" ]; then
        [ -f "$tools_base/SHA256SUMS" ] || die '需要离线包同目录的 SHA256SUMS，必须传递整个交付目录'
        expected="$(awk -v path="tools/$arch/$filename" '{name=$2;sub(/^\.\//,"",name);if(name==path) print $1}' "$tools_base/SHA256SUMS")"
        [ -n "$expected" ] && [ "$(sha256_file "$archive")" = "$expected" ] || die "工具缺失或摘要不匹配: $archive"
        printf '%s\n' "$archive"
        return 0
    fi
    archive="$WORK_DIR/tools/$arch/$filename"
    mkdir -p "$(dirname "$archive")"
    if [ ! -f "$archive" ]; then curl -fL --connect-timeout 15 --max-time 600 "https://github.com/containerd/nerdctl/releases/download/v2.2.1/$filename" -o "$archive"; fi
    printf '%s\n' "$archive"
}
stage_tools() {
    [ "${INSTALL_NERDCTL:-true}" = true ] || return 0
    if [ "${COMPONENTS:-all}" = harbor ] && [ "${IMPORT_IMAGES:-true}" = false ]; then return 0; fi
    local arch archive
    while IFS= read -r arch; do
        archive="$(resolve_nerdctl_archive "$arch")"
        mkdir -p "$RUN_DIR/tools/$arch"
        tar -xOzf "$archive" nerdctl > "$RUN_DIR/tools/$arch/nerdctl"
        elf_arch "$RUN_DIR/tools/$arch/nerdctl" "$arch"
        chmod 700 "$RUN_DIR/tools/$arch/nerdctl"
    done < <(printf '%s\n' "${ARCHES[@]}" | sort -u)
}
install_k8s_nodes_nerdctl() {
    [ "${INSTALL_NERDCTL:-true}" = true ] && [ "${COMPONENTS:-all}" != harbor ] || return 0
    local line archive
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        parse_node "$line"
        if has_role control_plane || has_role worker; then
            archive="$(resolve_nerdctl_archive "$NODE_ARCH")"
            node_run "$ROOT/node_scripts/mkdir-state.sh"
            node_upload "$archive" /etc/kubekey/rise/nerdctl.tar.gz
            node_run "$ROOT/node_scripts/nerdctl.sh" /etc/kubekey/rise/nerdctl.tar.gz "$NODE_ARCH" | tee "$RUN_DIR/$NODE_NAME.nerdctl.log"
        fi
    done < <(active_node_lines)
}
prepare_dependencies() {
    [ "$DEPS_MODE" != iso ] || [ -n "$ARTIFACT_FILE" ] || die 'ISO 依赖模式需要离线包'
    [ "$DEPS_MODE" != iso ] || check_work_disk "$WORK_DIR"
    local line nfs iso
    while IFS= read -r line; do
        parse_node "$line"; nfs=0; iso='-'
        if [ "${COMPONENTS:-all}" != harbor ] && [ "$NFS_MODE" = new ] && [ "$NFS_NODE" = "$NODE_NAME" ]; then nfs=1; fi
        if [ "$DEPS_MODE" = iso ]; then
            stage_iso
            node_run "$ROOT/node_scripts/mkdir-state.sh"
            node_upload "$ISO_FILE" /etc/kubekey/rise/deps.iso
            iso=/etc/kubekey/rise/deps.iso
        elif [ "$DEPS_MODE" = bootstrap ]; then
            bootstrap_archive="$BOOTSTRAP_ARCHIVE"
            if [ -z "$bootstrap_archive" ]; then
                token=jammy
                case "$NODE_OS" in
                    ubuntu-24.04-debs) token=noble;;
                    ubuntu-22.04-debs) token=jammy;;
                    kylin-v10SP3-2403-rpms) token=ky10;;
                esac
                arch="$NODE_ARCH"; [ "$arch" != arm64 ] || arch=aarch64
                for candidate in "$ROOT/bootstrap/bootstrap-$token-$arch.tar.gz" "$ROOT/bootstrap/bootstrap-$token-$NODE_ARCH.tar.gz"; do
                    if [ -f "$candidate" ]; then bootstrap_archive="$candidate"; break; fi
                done
            fi
            [ -n "$bootstrap_archive" ] && [ -f "$bootstrap_archive" ] || die "$NODE_NAME 缺少可用的 bootstrap 离线包"
            node_run "$ROOT/node_scripts/mkdir-state.sh"
            node_upload "$bootstrap_archive" /etc/kubekey/rise/bootstrap.tar.gz
            iso=/etc/kubekey/rise/bootstrap.tar.gz
        fi
        node_run "$ROOT/node_scripts/deps.sh" "$DEPS_MODE" "$iso" "$nfs" | tee "$RUN_DIR/$NODE_NAME.deps.log"
    done < <(active_node_lines)
    install_k8s_nodes_nerdctl
}
