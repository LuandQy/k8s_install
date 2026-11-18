#!/usr/bin/env bash
# Configure only the selected role; existing means observe, never rewrite.
set -euo pipefail
action="$1"; kind="$2"; sources="$3"; clients="$4"; allow_local="$5"; correction="$6"; cluster="$7"
export LC_ALL=C
test "$(id -u)" = 0
command -v chronyc >/dev/null
command -v chronyd >/dev/null
config=/etc/chrony.conf; unit=chronyd
if [ -d /etc/chrony ]; then config=/etc/chrony/chrony.conf; unit=chrony; fi
if [ "$kind" != existing ]; then
    test ! -L "$config"
    tmp=$(mktemp "${config}.rise.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    {
        printf '# rise-managed:%s\n' "$cluster"
        printf 'driftfile /var/lib/chrony/drift\nrtcsync\n'
        # Do not step an already running cluster clock; convergence is verified.
        servers=()
    IFS=, read -r -a servers <<< "$sources"
        for server in "${servers[@]}"; do [ -z "$server" ] || printf 'server %s iburst\n' "$server"; done
        if [ "$kind" = server ]; then
            for client in $clients; do printf 'allow %s/32\n' "$client"; done
            if [ -z "$sources" ]; then
                [ "$allow_local" = true ] || { echo '本地时间源未获显式配置' >&2; exit 1; }
                printf 'local stratum 10\n'
            fi
        fi
    } > "$tmp"
    # Parse before changing a working configuration.
    chronyd -p -f "$tmp" >/dev/null
    if [ "$action" = apply ]; then
        if [ -f "$config" ] && grep -q '^# rise-managed:' "$config"; then
            grep -qxF "# rise-managed:$cluster" "$config" || { echo 'chrony 配置属于其他集群' >&2; exit 1; }
        elif [ -f "$config" ]; then
            backup="${config}.before-rise-${cluster}"
            [ -e "$backup" ] || cp -p "$config" "$backup"
        fi
        if ! cmp -s "$config" "$tmp"; then
            chmod 644 "$tmp"; mv "$tmp" "$config"
            systemctl enable "$unit" >&2
            systemctl restart "$unit" >&2
        else
            systemctl enable --now "$unit" >&2
        fi
    else
        cmp -s "$config" "$tmp" || { echo 'NTP 配置与计划不一致，请显式重跑 services-init' >&2; exit 1; }
    fi
fi
systemctl is-active --quiet "$unit"
# A local reference deliberately has no external synchronisation. chronyc waitsync
# rejects it, so prove this exact local configuration is ready without calling it
# externally synchronised. Every other role retains the upstream convergence gate.
local_tracking_ready() {
    printf '%s\n' "$1" | awk -F, -v limit="$correction" '
        function finite_number(value, formatted) {
            if (value !~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/) return 0
            formatted = sprintf("%.17g", value + 0)
            return formatted ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/
        }
        function fail(reason) { print reason; exit 1 }
        END {
            if (!finite_number(limit) || limit + 0 <= 0) fail("correction limit must be finite and positive")
            if (NR != 1 || NF != 14) fail("tracking must contain exactly one 14-field CSV record")
            if ($1 != "7F7F0101") fail("reference ID is not the local reference 7F7F0101")
            if ($2 != "") fail("local reference name must be empty")
            if ($3 != "10") fail("local stratum must be exactly 10")
            if ($14 != "Normal") fail("leap status must be Normal")
            if (!finite_number($5)) fail("remaining correction offset is not a finite number")
            offset = $5 + 0
            if (offset < 0) offset = -offset
            if (offset > limit + 0) fail("absolute remaining correction offset exceeds limit " limit)
        }
    '
}
if [ "$kind" = server ] && [ -z "$sources" ] && [ "$allow_local" = true ]; then
    command -v timeout >/dev/null || { echo '[ERROR] 本地时间源就绪检查缺少 timeout' >&2; exit 1; }
    deadline=$((SECONDS + 40)); ready=false; tracking=''; reason='no tracking response'
    for ((attempt=1; attempt<=20; attempt++)); do
        remaining=$((deadline - SECONDS))
        [ "$remaining" -gt 0 ] || break
        query_timeout=2; [ "$remaining" -ge 2 ] || query_timeout="$remaining"
        if tracking=$(timeout "$query_timeout" chronyc -c tracking 2>&1); then
            if reason=$(local_tracking_ready "$tracking"); then ready=true; break; fi
        else
            query_status=$?
            reason="chronyc tracking failed with exit code $query_status"
        fi
        printf '[等待本地时间源 %s/20] %s; tracking=%s\n' "$attempt" "$reason" "$tracking" >&2
        remaining=$((deadline - SECONDS))
        if [ "$attempt" -lt 20 ] && [ "$remaining" -gt 0 ]; then
            pause=2; [ "$remaining" -ge 2 ] || pause="$remaining"
            sleep "$pause"
        fi
    done
    if [ "$ready" != true ]; then
        printf '[ERROR] 本地无上游时间源未就绪：%s; tracking=%s\n' "$reason" "$tracking" >&2
        exit 1
    fi
else
    # Bound convergence wait to 40 seconds per node. Failure blocks installation.
    if chronyc waitsync 20 "$correction" 0 2 >&2; then
        tracking=$(chronyc -c tracking)
    else
        wait_status=$?
        printf '[ERROR] NTP waitsync 失败：kind=%s sources=%s exit=%s\n' "$kind" "$sources" "$wait_status" >&2
        chronyc -c tracking >&2 || true
        exit "$wait_status"
    fi
fi
printf 'tracking=%s\n' "$tracking"
selected=$(chronyc -n sources)
printf '%s\n' "$selected"
if [ "$kind" = client ]; then
    printf '%s\n' "$selected" | awk -v expected="$sources" '$1=="^*" && $2==expected {ok=1} END {exit !ok}' || { echo '客户端未同步到指定 NTP 节点' >&2; exit 1; }
fi
if [ "$kind" = external ] || { [ "$kind" = server ] && [ -n "$sources" ]; }; then
    printf '%s\n' "$selected" | awk '$1=="^*" {ok=1} END {exit !ok}' || { echo '没有选中的上游时间源' >&2; exit 1; }
fi
if [ "$kind" = server ] && [ -z "$sources" ]; then printf 'time_basis=local_unreferenced\n'
elif [ "$kind" = existing ]; then printf 'time_basis=site_configuration\n'
else printf 'time_basis=observed_source\n'; fi
