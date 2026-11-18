#!/usr/bin/env bash
# Synchronize .workflow snapshot and execute unified post-verification + ledger after redeploy or scale-worker.

workflow_sync_and_post_verify() {
    local summary_json="$1" saved_env="$ENV_FILE" saved_run="$RUN_DIR" step
    [ -s "$summary_json" ] || die "维护后置同步缺少节点检查摘要: $summary_json"
    [ -f "$STATE_DIR/cluster.env" ] || die "维护后置同步缺少最新集群参数: $STATE_DIR/cluster.env"

    WF_DIR="${STATE_DIR}.workflow"
    umask 077
    mkdir -p "$WF_DIR"
    cp "$STATE_DIR/cluster.env" "$WF_DIR/effective.env"
    sha256_file "$WF_DIR/effective.env" > "$WF_DIR/effective.sha256"
    resume_identity "$summary_json" > "$WF_DIR/identity.json"
    sha256_file "$WF_DIR/identity.json" > "$WF_DIR/identity.sha256"
    printf '%s\n' "${COMPONENTS:-all}" > "$WF_DIR/prepare-scope"

    ENV_FILE="$STATE_DIR/cluster.env"
    WF_SOURCE="$ENV_FILE"
    WF_FINGERPRINT="$(workflow_fingerprint)"
    printf '%s\n' "$WF_FINGERPRINT" > "$WF_DIR/fingerprint"

    # Stamp completed installation stages under the refreshed topology fingerprint
    for step in deps k8s-install; do
        workflow_write "$step" succeeded
    done
    if [ "${COMPONENTS:-all}" != k8s ] && [ "${REGISTRY_MODE:-harbor}" != external-harbor ]; then
        workflow_write harbor-install succeeded
        [ "${IMPORT_IMAGES:-true}" != true ] || {
            workflow_write harbor-projects succeeded
            workflow_write images-import succeeded
        }
    fi

    if [ "${SKIP_POST_VERIFY:-false}" = true ]; then
        ENV_FILE="$saved_env"
        RUN_DIR="$saved_run"
        log "已同步 ${WF_DIR} 拓扑快照，并按 --skip-post-verify 跳过深度验收"
        return 0
    fi

    local post_steps=(ledger)
    if [ "${HARBOR_HTTP:-false}" = false ] && [ "${COMPONENTS:-all}" != harbor ]; then
        post_steps=(services-verify images-verify node-images-verify cluster-verify ledger)
    fi

    for step in "${post_steps[@]}"; do
        RUN_DIR="$saved_run/post-$step"
        mkdir -p "$RUN_DIR"
        export RUN_DIR
        workflow_write "$step" running
        if workflow_run_step "$step"; then
            workflow_write "$step" succeeded
        else
            workflow_write "$step" failed
            ENV_FILE="$saved_env"
            RUN_DIR="$saved_run"
            die "维护后置验收阶段 $step 失败，详情见 $saved_run/post-$step"
        fi
    done

    ENV_FILE="$saved_env"
    RUN_DIR="$saved_run"
    export RUN_DIR
    log "维护后置深度验收与台账已同步刷新: $saved_run"
}
