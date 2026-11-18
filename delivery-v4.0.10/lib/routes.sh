#!/usr/bin/env bash
# Classify, never suppress, overlaps. Fresh installs reject both classes.
# Resume authorizes Calico candidates only after checking node ownership.
route_conflicts() {
    local file="$1" route cidr first last lo hi pod_lo pod_hi value managed
    read -r pod_lo pod_hi <<< "$(cidr_bounds "$POD_CIDR")"
    while IFS= read -r route; do
        cidr=$(jq -r '.dst' <<< "$route")
        read -r first last <<< "$(cidr_bounds "$cidr")"
        managed=false
        if [ "$first" -ge "$pod_lo" ] && [ "$last" -le "$pod_hi" ] &&
            jq -e '.protocol=="bird" and (.type=="blackhole" or (.dev=="tunl0" and ((.type // "unicast")=="unicast")))' <<< "$route" >/dev/null; then
            managed=true
        fi
        for value in "$POD_CIDR" "$SERVICE_CIDR"; do
            read -r lo hi <<< "$(cidr_bounds "$value")"
            if [ "$first" -le "$hi" ] && [ "$lo" -le "$last" ]; then
                if [ "$managed" = true ] && [ "$value" = "$POD_CIDR" ]; then
                    printf 'RISE_CONFLICT=Calico路由:%s\n' "$cidr"
                else
                    printf 'RISE_CONFLICT=路由与集群CIDR重叠:%s\n' "$cidr"
                fi
            fi
        done
    done < <(jq -c '.[] | select((.dst // "default")!="default") | select(.dst|contains("/") and (endswith("/32")|not))' "$file")
}
