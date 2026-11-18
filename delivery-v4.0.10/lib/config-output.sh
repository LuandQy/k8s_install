#!/usr/bin/env bash
# Versioned read-only adapter. Never serialize the shell environment or secrets.
config_nodes_json() {
    jq -Rsc 'split("\n") | map(select(length>0) | split("|") |
      {name:.[0], address:.[1], internal_address:.[2], user:.[3], port:(.[4]|tonumber),
       arch:.[5], os:.[6], roles:(.[7]|split(",")), connection:.[8],
       data_path:.[9], data_mode:.[10]})'
}
config_report_json() {
    local kind="$1" nodes active row steps='[]'
    nodes=$(node_lines | config_nodes_json)
    active=$(while IFS= read -r row; do
        parse_node "$row"
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$NODE_NAME" "$NODE_ADDRESS" "$NODE_INTERNAL" "$NODE_USER" "$NODE_PORT" \
            "$NODE_ARCH" "$NODE_OS" "$(component_effective_roles "$NODE_ROLES")" \
            "$NODE_CONNECTION" "$NODE_DATA" "$NODE_DATA_MODE"
    done < <(active_node_lines) | config_nodes_json)
    [ "$kind" != plan ] || steps=$(workflow_steps all | jq -Rsc 'split("\n")|map(select(length>0))')
    jq -n --arg kind "$kind" --arg cluster "$CLUSTER_NAME" --arg components "$COMPONENTS" \
        --arg version "$KUBE_VERSION" --arg pod "$POD_CIDR" --arg service "$SERVICE_CIDR" \
        --arg registry "$REGISTRY_MODE" --arg registry_host "$HARBOR_DOMAIN" \
        --arg registry_port "$HARBOR_PORT" --arg deps "$DEPS_MODE" \
        --arg verify "$CLUSTER_VERIFY_MODE" --argjson nodes "$nodes" --argjson active "$active" \
        --argjson steps "$steps" --argjson import_images "$IMPORT_IMAGES" \
        --argjson local_storage "$LOCAL_STORAGE" \
        '{schema_version:1,kind:$kind,valid:true,config_source:"trusted-bash-env",
          execution_authorized:false,live_checks_performed:false,
          config:{cluster_name:$cluster,components:$components,kubernetes_version:$version,
            networking:{pod_cidr:$pod,service_cidr:$service},
            registry:{mode:$registry,domain:$registry_host,port:($registry_port|tonumber),import_images:$import_images},
            dependencies:{mode:$deps},verification:{mode:$verify,local_storage:$local_storage},
            declared_nodes:$nodes,active_nodes:$active},
          intended_operation:(if $kind=="plan" then "all" else null end),steps:$steps}'
}
deployment_plan_json() {
    local blockers='[]'
    # Only known static blockers; an empty list is never an installation permit.
    if [ -z "$ARTIFACT_FILE" ] || [ ! -f "$ARTIFACT_FILE" ]; then
        blockers=$(jq -c '.+["artifact_missing"]' <<< "$blockers")
    fi
    if [ "$DEPS_MODE" = online ]; then blockers=$(jq -c '.+["online_dependencies_unsupported"]' <<< "$blockers"); fi
    if [ "$COMPONENTS" != harbor ] && [ "$HARBOR_HTTP" = true ]; then
        blockers=$(jq -c '.+["cluster_verification_requires_https"]' <<< "$blockers")
    fi
    config_report_json plan | jq --argjson blockers "$blockers" \
        '.+{blockers:$blockers,checks_not_performed:["artifact_digest_and_contents","node_access_and_identity","storage_and_memory","deployment_receipts","live_health","continuous_io_monitoring"]}'
}
