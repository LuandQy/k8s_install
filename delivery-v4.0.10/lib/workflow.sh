#!/usr/bin/env bash
# Public staged installation. Never source this file to perform actions.
. "$ROOT/lib/access.sh"
. "$ROOT/lib/services.sh"
. "$ROOT/lib/node-images.sh"
. "$ROOT/lib/cluster-verify.sh"
. "$ROOT/lib/ledger.sh"
workflow_fingerprint() {
    local base
    { sha256_file "$ENV_FILE"; resume_project_digest;
      if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then printf 'SSH_KNOWN_HOSTS=%s\n' "$SSH_KNOWN_HOSTS"; ssh_known_hosts_digest; fi
      for base in "$ROOT"/lib/*.sh "$ROOT"/lib/*.py "$ROOT"/node_scripts/*.sh "$ROOT/deploy.sh" "$ROOT/init.sh" "$ROOT/check.sh" \
                  "$ROOT/config-base.yaml" "$ROOT/inventory-base.yaml" "$ROOT/lib/calico-images.json" "$ROOT/lib/kk-binaries.sha256"; do sha256_file "$base"; done
    } | resume_stdin_digest
}
workflow_steps() {
    case "$1" in
        all|install|resume)
            [ "$1" = install ] || printf '%s\n' access prepare deps services-init
            printf '%s\n' services-verify
            if [ "$COMPONENTS" != k8s ]; then
                printf '%s\n' harbor-install
                if [ "$IMPORT_IMAGES" = true ]; then printf '%s\n' harbor-projects images-import images-verify; fi
            else printf '%s\n' images-verify; fi
            [ "$COMPONENTS" = harbor ] || printf '%s\n' k8s-install node-images-verify cluster-verify
            printf '%s\n' ledger
            return 0;;
        init) printf 'prepare\n';;
        prepare)
            if [ "${DELIVERY_GRANULAR_STEP:-false}" = true ]; then
                printf 'prepare\n'
            elif [ ! -f "$WF_DIR/access.json" ] || [ "$(workflow_status access)" != succeeded ]; then
                printf '%s\n' access prepare deps services-init services-verify
            else
                printf '%s\n' prepare deps services-init services-verify
            fi;;
        harbor)
            printf '%s\n' harbor-install
            if [ "$IMPORT_IMAGES" = true ]; then printf '%s\n' harbor-projects images-import images-verify; fi
            ;;
        k8s)
            printf '%s\n' k8s-install node-images-verify cluster-verify ledger;;
        *) printf '%s\n' "$1";;
    esac
}
workflow_status() {
    [ -f "$WF_DIR/$1.json" ] || { printf pending; return; }
    local status file expected
    status=$(jq -er --arg fp "$WF_FINGERPRINT" 'select(.fingerprint==$fp) | .status' "$WF_DIR/$1.json") || die '阶段记录无效'
    if [ "$status" = succeeded ]; then
        file=$(jq -r '.evidence.path // empty' "$WF_DIR/$1.json")
        expected=$(jq -r '.evidence.sha256 // empty' "$WF_DIR/$1.json")
        [ -z "$file" ] || { [ -f "$file" ] && [ "$(sha256_file "$file")" = "$expected" ]; } || die "阶段 $1 验收证据已变化"
    fi
    printf '%s' "$status"
}
workflow_require() {
    local step
    for step in "$@"; do
        [ "$(workflow_status "$step")" = succeeded ] || die "请先完成阶段 ${step}；不会隐式执行前置步骤"
    done
}
workflow_write() {
    local tmp evidence=null file=''
    case "$1" in
        access) file="$RUN_DIR/access.json";;
        prepare) file="$RUN_DIR/preparation-evidence.json";;
        services-init|services-verify) file="$RUN_DIR/services-evidence.json";;
        images-verify) file="$RUN_DIR/images-evidence.json";;
        node-images-verify) file="$RUN_DIR/node-images-evidence.json";;
        cluster-verify) file="$RUN_DIR/cluster-verify-evidence.json";;
    esac
    if [ "$2" = succeeded ] && [ -n "$file" ]; then
        [ -s "$file" ] || die "阶段 $1 缺少验收证据"
        evidence=$(jq -n --arg path "$file" --arg sha "$(sha256_file "$file")" '{path:$path,sha256:$sha}')
    fi
    tmp=$(mktemp "$WF_DIR/.stage.XXXXXX")
    jq -n --arg stage "$1" --arg status "$2" --arg run "$RUN_DIR" --arg fingerprint "$WF_FINGERPRINT" \
        --arg time "$(date -u +%FT%TZ)" --argjson evidence "$evidence" \
        '{schema:2,stage:$stage,status:$status,run:$run,fingerprint:$fingerprint,updated_at:$time,evidence:$evidence}' > "$tmp"
    mv "$tmp" "$WF_DIR/$1.json"
}
workflow_exit() {
    local rc=$?
    trap - EXIT
    if [ -n "${WF_ACTIVE:-}" ]; then workflow_write "$WF_ACTIVE" failed; fi
    exit "$rc"
}
workflow_stop_checkpoint() {
    # The local Web executor supplies its own private marker. Check only at
    # stage boundaries: stopping never kills a node command or rolls it back.
    if [ -n "${DELIVERY_STOP_FILE:-}" ] && { [ -e "$DELIVERY_STOP_FILE" ] || [ -L "$DELIVERY_STOP_FILE" ]; }; then
        log '已按请求在阶段边界停止；已完成阶段和现场保留。核对后由管理员通过原 CLI 处理。' >&2
        exit 130
    fi
}
workflow_load_effective() {
    local file="$WF_DIR/effective.env"
    [ -f "$file" ] && [ "$(sha256_file "$file")" = "$(cat "$WF_DIR/effective.sha256")" ] || die '准备快照丢失或已修改'
    # Scope belongs to the current action, not the preparation snapshot.
    local scope="$COMPONENTS" import="$IMPORT_IMAGES"
    load_env "$file"
    COMPONENTS="$scope"; IMPORT_IMAGES="$import"; validate_env
}
workflow_verify_identity() {
    [ "$(sha256_file "$WF_DIR/identity.json")" = "$(cat "$WF_DIR/identity.sha256")" ] || die '准备阶段身份摘要不符'
    CLI_COMPONENTS="$COMPONENTS" RUN_DIR="$RUN_DIR/identity-check" bash "$ROOT/check.sh" --env "$WF_DIR/effective.env" --collect-only
    component_compare_prepared_identity "$WF_DIR/identity.json" "$RUN_DIR/identity-check/summary.json"
}
workflow_registry_settings() {
    # Render all future workload platforms, even during Harbor-only phases.
    local saved_arches=("${ARCHES[@]}") row
    ARCHES=()
    while IFS= read -r row; do parse_node "$row"; ARCHES+=("$NODE_ARCH"); done < <(node_lines)
    IMAGE_IMPORT_ONLY=true LIVE_RENDER=true render_configs
    selected_target_images > "$RUN_DIR/selected-images.json"
    jq --argjson arches "$(json_array "${ARCHES[@]}" | jq -c unique)" \
       --arg report "$RUN_DIR/images-evidence.json" \
       '. + {arches:$arches,verify_timeout:0,evidence_file:$report}' \
       "$RUN_DIR/harbor-settings.json" > "$RUN_DIR/settings.tmp"
    mv "$RUN_DIR/settings.tmp" "$RUN_DIR/harbor-settings.json"
    ARCHES=("${saved_arches[@]}")
}
workflow_registry_check() {
    progress_run "Harbor $1" "$RUN_DIR/harbor-${1#--}.log" bash "$ROOT/lib/harbor.sh" "$RUN_DIR/harbor-settings.json" "$1"
}
workflow_install() {
    local scope="$1" receipt action=install
    receipt="$STATE_DIR.deployment"; [ "$scope" != harbor ] || receipt="$STATE_DIR.harbor.deployment"
    if [ -e "$receipt/status" ]; then
        [ "$(cat "$receipt/status")" != complete ] || die '已有完成的安装回执；请核对阶段状态，不重装已完成组件'
        action=resume
    fi
    # The private installer retains identity/PKI/receipt checks. No deps/init here.
    [ -f "$WF_DIR/identity.json" ] && [ "$(sha256_file "$WF_DIR/identity.json")" = "$(cat "$WF_DIR/identity.sha256")" ] || die '准备阶段节点身份记录丢失或已修改'
    PREPARED_IDENTITY_FILE="$WF_DIR/identity.json" DELIVERY_STEP=true CLI_COMPONENTS="$scope" CLI_IMPORT_IMAGES=false RUN_DIR="$RUN_DIR/install" \
        bash "$ROOT/deploy.sh" "$action" --env "$WF_DIR/effective.env" -y
}
workflow_invalidate_images() {
    workflow_write images-verify pending
    workflow_write node-images-verify pending
    workflow_write cluster-verify pending
    local directory="$STATE_DIR.harbor" tmp
    [ -d "$directory" ] || return 0
    component_verify_harbor_state
    tmp=$(mktemp "$directory/.images.XXXXXX")
    jq '.images_ready=false' "$directory/identity.json" > "$tmp"
    mv "$tmp" "$directory/identity.json"; state_checksums "$directory"
}
workflow_record_images() {
    local directory="$STATE_DIR.harbor" tmp
    [ -d "$directory" ] || return 0
    component_verify_harbor_state
    [ -s "$RUN_DIR/images-evidence.json" ] || die '镜像验收证据缺失'
    tmp=$(mktemp "$directory/.images.XXXXXX")
    jq --arg file "$RUN_DIR/images-evidence.json" --arg sha "$(sha256_file "$RUN_DIR/images-evidence.json")" \
        --arg version "$KUBE_VERSION" '. + {images_ready:true,images_evidence:$file,images_evidence_sha256:$sha,images_version:$version}' \
        "$directory/identity.json" > "$tmp"
    mv "$tmp" "$directory/identity.json"; state_checksums "$directory"
}
workflow_preparation_evidence() {
    local row dir
    : > "$RUN_DIR/snapshots.jsonl"
    while IFS= read -r row; do
        parse_node "$row"; dir="$RUN_DIR/init/precheck/reports/$NODE_NAME"
        [ -f "$dir/BLOCKS.json" ] && [ -f "$dir/MOUNTS.json" ] || continue
        sed -n -E 's/^RISE_(OS|OS_VERSION|KERNEL|CPU_CORES|MEM_KB)=(.*)$/\1=\2/p' "$dir/identity.log" | \
            jq -Rn '[inputs|split("=")|{key:.[0],value:.[1]}]|from_entries' > "$RUN_DIR/system.json"
        jq -n --arg name "$NODE_NAME" --slurpfile blocks "$dir/BLOCKS.json" --slurpfile mounts "$dir/MOUNTS.json" \
            --slurpfile system "$RUN_DIR/system.json" '{key:$name,value:{blocks:$blocks[0],mounts:$mounts[0],system:$system[0]}}' >> "$RUN_DIR/snapshots.jsonl"
    done < <(node_lines)
    jq -s from_entries "$RUN_DIR/snapshots.jsonl" > "$RUN_DIR/snapshots.json"
    node_lines | jq -Rn --slurpfile identity "$WF_DIR/identity.json" --slurpfile snapshots "$RUN_DIR/snapshots.json" \
        '{identity:$identity[0],snapshots:$snapshots[0],storage:[inputs|split("|")|{node:.[0],mode:.[10],path:.[9],device:.[11]}]}' > "$RUN_DIR/preparation-evidence.json"
}
workflow_write_hosts() {
    local row block='' harbor=''
    while IFS= read -r row; do
        parse_node "$row"
        block+="$NODE_INTERNAL $NODE_NAME"$'\n'
    done < <(node_lines)
    if [ "$COMPONENTS" != k8s ] && [ "${REGISTRY_MODE:-harbor}" != external-harbor ]; then
        harbor=$(component_registry_address) || die '无法确定 Harbor 地址，不能写入 /etc/hosts'
        block+="$harbor $HARBOR_DOMAIN"$'\n'
    fi
    [ -n "$block" ] || die '集群 hosts 内容为空'
    while IFS= read -r row; do
        parse_node "$row"
        node_run "$ROOT/node_scripts/hosts.sh" "$block" || die "$NODE_NAME /etc/hosts 写入失败；请核对已有冲突映射"
    done < <(node_lines)
}
workflow_run_step() {
    local step="$1" scope="$COMPONENTS" import="$IMPORT_IMAGES" prep_scope
    component_assert_registry_action "$step"
    case "$step" in
        access)
            access_run
            cp "$RUN_DIR/access.json" "$WF_DIR/access-identity.json"
            sha256_file "$WF_DIR/access-identity.json" > "$WF_DIR/access-identity.sha256";;
        prepare)
            workflow_require access
            # Prepare the entire declared future topology before Harbor starts its
            # shared Docker/containerd runtime. Never prepare these paths again.
            prep_scope=all
            [ "${#CONTROL_PLANES[@]}" -gt 0 ] || prep_scope=harbor
            [ "$scope" != k8s ] || prep_scope=k8s
            if [ "$NONINTERACTIVE" = true ]; then
                while IFS= read -r row; do
                    parse_node "$row"
                    [[ "$NODE_DATA_MODE" = native || "$NODE_DATA_MODE" = existing ]] || die '静默准备仅允许 native/existing，不能选择或格式化磁盘'
                done < <(node_lines)
            fi
            [ "$(sha256_file "$WF_DIR/access-identity.json")" = "$(cat "$WF_DIR/access-identity.sha256")" ] || die '接入身份记录已修改'
            CLI_COMPONENTS="$prep_scope" RUN_DIR="$RUN_DIR/access-check" bash "$ROOT/check.sh" --env "$WF_SOURCE" --collect-only
            component_compare_prepared_identity "$WF_DIR/access-identity.json" "$RUN_DIR/access-check/summary.json"
            workflow_write_hosts
            printf '%s\n' "$RUN_DIR" > "$WF_DIR/prepare-started"
            DELIVERY_ACCESS_READY=true DELIVERY_PREPARE=true CLI_COMPONENTS="$prep_scope" RUN_DIR="$RUN_DIR/init" bash "$ROOT/init.sh" all --env "$WF_SOURCE"
            resume_identity "$RUN_DIR/init/precheck/summary.json" > "$WF_DIR/identity.json"
            sha256_file "$WF_DIR/identity.json" > "$WF_DIR/identity.sha256"
            cp "$RUN_DIR/init/effective.env" "$WF_DIR/effective.env"
            sha256_file "$WF_DIR/effective.env" > "$WF_DIR/effective.sha256"
            printf '%s\n' "$prep_scope" > "$WF_DIR/prepare-scope"
            workflow_load_effective
            workflow_preparation_evidence;;
        deps)
            workflow_require prepare; workflow_load_effective
            COMPONENTS=$(cat "$WF_DIR/prepare-scope"); validate_env
            workflow_verify_identity
            [ "$DEPS_MODE" != online ] || die '分步离线安装禁止 online 依赖模式'
            preflight_artifact; prepare_dependencies;;
        services-init|services-verify)
            workflow_require prepare deps; workflow_load_effective
            [ "$step" != services-verify ] || workflow_require services-init
            COMPONENTS=$(cat "$WF_DIR/prepare-scope"); validate_env
            workflow_verify_identity
            if [ "$step" = services-init ]; then
                workflow_write services-verify pending
                workflow_write cluster-verify pending
                services_run apply
            else services_run verify; fi;;
        node-images-verify)
            workflow_require k8s-install services-verify; workflow_load_effective
            COMPONENTS=k8s; validate_env
            workflow_write cluster-verify pending
            workflow_verify_identity
            workflow_registry_settings
            workflow_registry_check --preflight || { workflow_invalidate_images; die '节点拉取前仓库验收失败'; }
            node_images_verify;;
        cluster-verify)
            workflow_require k8s-install services-verify images-verify node-images-verify
            workflow_load_effective
            COMPONENTS=k8s; validate_env
            workflow_verify_identity
            progress_run '集群功能验收（DNS/TLS/Service/PVC）' "$RUN_DIR/cluster-verify.log" cluster_verify;;
        ledger) ledger_build;;
        harbor-install|k8s-install)
            workflow_require prepare deps services-init services-verify; workflow_load_effective
            COMPONENTS=$(cat "$WF_DIR/prepare-scope"); validate_env
            workflow_verify_identity
            workflow_write services-verify pending
            services_run verify
            workflow_write services-verify succeeded
            if [ "$step" = k8s-install ]; then
                workflow_require images-verify
                COMPONENTS=k8s; IMPORT_IMAGES=false; validate_env
                workflow_registry_settings
                workflow_registry_check --preflight || { workflow_invalidate_images; die '镜像实时核验失败，未安装 K8s'; }
                workflow_install k8s
            else
                COMPONENTS=harbor; IMPORT_IMAGES=false; validate_env
                workflow_install harbor
                component_sync_registry_ca
            fi;;
        harbor-projects|images-import|images-verify)
            workflow_require prepare; workflow_load_effective
            workflow_registry_settings
            case "$step" in
                harbor-projects) workflow_registry_check projects;;
                images-import)
                    workflow_require harbor-projects
                    # Invalidate verification BEFORE a write, including failed imports.
                    workflow_invalidate_images
                    preflight_artifact; choose_kk; check_work_disk "$WORK_DIR"
                    workflow_registry_check --projects-check
                    args=(run --workdir "$WORK_DIR" playbooks/import_images.yaml --project-addr "$ROOT/kk-project" -i "$RUN_DIR/inventory.yaml" -c "$RUN_DIR/config.yaml" -a "$ARTIFACT_FILE")
                    kk_ssh_preflight "$WF_DIR/identity.json"
                    progress_run 'KubeKey 镜像导入' "$RUN_DIR/kubekey-images.log" "$KK" "${args[@]}"
                    workflow_registry_check --preflight;;
                images-verify) workflow_invalidate_images; workflow_registry_check --preflight; workflow_record_images;;
            esac;;
        *) die "未知分步操作: $step";;
    esac
    COMPONENTS="$scope"; IMPORT_IMAGES="$import"
}
workflow_main() {
    local requested="$1" step previous base
    workflow_stop_checkpoint
    component_assert_registry_action "$requested"
    [ "$requested:$COMPONENTS" != cluster-verify:harbor ] || die 'cluster-verify 需要 K8s 范围，不能用于仅 Harbor 配置'
    case "$requested" in all|install|resume|cluster-verify)
        [ "$COMPONENTS" = harbor ] || [ "$HARBOR_HTTP" = false ] || die '当前 cluster-verify 要求 HTTPS Harbor；组合 K8s 流程已在任何安装前停止，不能将 HTTP 检查冒充 TLS 验收';;
    esac
    [ -z "${RUN_DIR:-}" ] || die '分步执行使用自动运行目录；--output 仅用于 render'
    [ "$COMPONENTS" != all ] || [ "$IMPORT_IMAGES" = true ] || die '整套安装不能跳过镜像导入'
    case "$requested" in all|install|resume) ledger_require_runtime;; esac
    [ "$requested" = access ] || [ "$DEPS_MODE" != online ] || die '分步交付禁止 online 依赖模式，请配置离线 ISO 或 preinstalled'
    linux_root; controller_lock; assert_no_pending_expansion
    [ "$requested" = access ] || [ -n "$ARTIFACT_FILE" ] || die '分步交付要求完整离线包，不允许隐式联网'
    [ "$(cat "$STATE_DIR.deployment/status" 2>/dev/null || true)" != reset ] || die '集群已 reset，请使用 redeploy；不能复用旧分步成功记录'
    WF_SOURCE="$ENV_FILE"; WF_DIR="$STATE_DIR.workflow"
    if [ ! -d "$WF_DIR" ] && { [ -e "$STATE_DIR.deployment" ] || [ -e "$STATE_DIR.harbor.deployment" ]; }; then
        die '检测到旧版安装回执，不能直接接管为新分步流程；请使用原维护入口'
    fi
    # Bind to original input and execution code; CLI scope changes are permitted,
    # topology/storage/versions/code changes require explicit new planning.
    WF_FINGERPRINT=$(workflow_fingerprint)
    if [ -f "$WF_DIR/fingerprint" ]; then
        [ "$WF_FINGERPRINT" = "$(cat "$WF_DIR/fingerprint")" ] || die '配置或执行代码变化，拒绝复用阶段记录；保留记录，先核对变更'
    fi
    if [ "${cli_noninteractive:-false}" = true ]; then NONINTERACTIVE=true; fi
    export NONINTERACTIVE
    if [ "$NONINTERACTIVE" != true ]; then
        wizard_summary
        ask_valid '1 执行以上范围；0 取消' 0 '0|1'
        [ "$REPLY" = 1 ] || return 0
    fi
    # prepare/deps do not need registry credentials.
    case "$requested" in access|prepare|init|deps|services-init|services-verify|cluster-verify) ;;
        *)
            if [ "$COMPONENTS" != k8s ]; then
                if [ -z "${HARBOR_PASSWORD:-}" ] && [ "$NONINTERACTIVE" != true ]; then ask_secret HARBOR_PASSWORD 'Harbor 密码（隐藏输入）: '; fi
                validate_password
            fi;;
    esac
    if [ "$SSH_AUTH_MODE" = password ] && [ "$NONINTERACTIVE" != true ]; then
        while IFS= read -r row; do
            parse_node "$row"
            [ "$NODE_CONNECTION" = ssh ] || continue
            [ -n "$NODE_PASS_ENV" ] || die "$NODE_NAME 密码模式缺少密码变量名"
            [ -n "${!NODE_PASS_ENV:-}" ] || ask_secret "$NODE_PASS_ENV" "$NODE_NAME SSH 密码（隐藏输入）: "
        done < <(node_lines)
    fi
    # Commit local workflow binding only after confirmation and credential checks.
    # A cancelled all/install action leaves neither state nor runs behind.
    umask 077; mkdir -p "$WF_DIR"
    [ -f "$WF_DIR/fingerprint" ] || printf '%s\n' "$WF_FINGERPRINT" > "$WF_DIR/fingerprint"
    new_run
    base="$RUN_DIR"; trap workflow_exit EXIT
    while IFS= read -r step; do
        workflow_stop_checkpoint
        previous=$(workflow_status "$step") || die "阶段 $step 状态无法复用"
        # Installed components and preparation are never implicitly replayed.
        # Explicit project/import commands may repair deleted registry content.
        # Verification is always live and produces new evidence.
        if [ "$previous" = succeeded ] && [ "$step" != images-verify ] && [ "$step" != services-verify ] && [ "$step" != node-images-verify ] && [ "$step" != cluster-verify ] && [ "$step" != ledger ] &&
           ! { [ "$requested" = "$step" ] && { [ "$step" = images-import ] || [ "$step" = harbor-projects ] || [ "$step" = services-init ] || [ "$step" = access ]; }; }; then
            log "阶段已完成，跳过 ${step}（安装前仍核验准备结果、仓库和节点身份）"; continue
        fi
        if [ "$step" = prepare ] && [ "$previous" != pending ] && [ -f "$WF_DIR/prepare-started" ]; then
            die '初始化曾中断，禁止自动重复存储操作；请核对原日志与实际挂载'
        fi
        RUN_DIR="$base/$step"; mkdir "$RUN_DIR"; export RUN_DIR
        WF_ACTIVE="$step"; workflow_write "$step" running
        workflow_run_step "$step"
        workflow_write "$step" succeeded; WF_ACTIVE=
    done < <(workflow_steps "$requested")
    workflow_stop_checkpoint
    trap - EXIT
    log "分步流程完成；记录: ${WF_DIR}；日志: $base"
}
