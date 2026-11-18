#!/usr/bin/env bash
# Executed by the scoped KubeKey reset playbook; never flush host/Docker routes.
set -euo pipefail
action=${1:-${RISE_RESET_ACTION:-verify}}
pod_cidr=${2:-${RISE_RESET_POD_CIDR:?missing managed Pod CIDR}}
[[ "$action" = cleanup || "$action" = verify ]] || exit 1
# Return success only for valid IPv4 ranges which overlap this cluster's Pod CIDR.
overlaps() {
    awk -v a="$1" -v b="$pod_cidr" '
    function bounds(c, r, n,i,v,p,step) {
        n=split(c,r,"/"); if(n!=2 || r[2]!~/^[0-9]+$/ || r[2]>32) exit 2
        p=r[2]; n=split(r[1],r,"."); if(n!=4) exit 2
        v=0; for(i=1;i<=4;i++){if(r[i]!~/^[0-9]+$/ || r[i]>255)exit 2; v=v*256+r[i]}
        step=2^(32-p); lo=int(v/step)*step; hi=lo+step-1
    }
    BEGIN {bounds(a); al=lo; ah=hi; bounds(b); exit !(al<=hi && lo<=ah)}'
}
overlaps "$pod_cidr" || { echo '[ERROR] 无效 Pod CIDR'; exit 1; }
calico_links() {
    local snapshot
    snapshot=$(ip -o link show) || return 1
    printf '%s\n' "$snapshot" | awk -F ': ' '{split($2,a,"@"); if(a[1]=="tunl0" || a[1]=="vxlan.calico" || a[1]~/^cali[0-9a-f]+$/) print a[1]}'
}
if [ "$action" = cleanup ]; then
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        if [ "$dev" = tunl0 ]; then
            # Linux's fallback IPIP device cannot always be deleted. Disable it
            # and remove its Calico address; never unload a shared kernel module.
            ip -4 address flush dev tunl0 scope global
            ip link set dev tunl0 down
        else
            ip link delete dev "$dev"
        fi
    done < <(calico_links)
    # Calico BIRD blackhole routes survive interface removal and kubeadm reset.
    routes=$(ip -4 route show)
    while IFS= read -r route; do
        read -r -a fields <<< "$route"
        [ "${#fields[@]}" -gt 0 ] || continue
        kind=${fields[0]}
        if [ "$kind" = blackhole ]; then
            cidr=${fields[1]:-}
        else
            # Bringing Linux's fallback IPIP interface down does not necessarily
            # remove routes to other Calico nodes. Keep all other routes intact.
            [[ " $route " = *' dev tunl0 '* ]] || continue
            cidr=$kind
        fi
        [[ " $route " = *' proto bird '* ]] || continue
        [[ "$cidr" = */* ]] || continue
        overlaps "$cidr" || continue
        # Only delete Calico blocks wholly contained in this cluster's Pod CIDR.
        [ "${cidr##*/}" -ge "${pod_cidr##*/}" ] || continue
        ip -4 route del "${fields[@]}"
    done <<< "$routes"
fi
links=$(calico_links)
if printf '%s\n' "$links" | grep -qx tunl0; then
    tunnel=$(ip -o link show tunl0)
    addresses=$(ip -o -4 address show dev tunl0 scope global)
    if [[ "$tunnel" != *',UP,'* && "$tunnel" != *'<UP,'* && "$tunnel" != *',UP>'* ]] && [ -z "$addresses" ]; then
        links=$(printf '%s\n' "$links" | sed '/^tunl0$/d')
    fi
fi
[ -z "$links" ] || { printf '[ERROR] Calico 接口残留: %s\n' "$links"; exit 1; }
routes=$(ip -4 route show)
while read -r first second rest; do
    case "$first" in default|'') continue;; blackhole|unreachable|prohibit|throw) cidr="$second";; *) cidr="$first";; esac
    case "$cidr" in */*) ;; *) cidr="$cidr/32";; esac
    if overlaps "$cidr"; then
        printf '[ERROR] 重置后仍有路由与 Pod CIDR 重叠，需核对: %s %s %s\n' "$first" "$second" "$rest"
        exit 1
    fi
done <<< "$routes"
printf '[OK] Calico 接口与 Pod CIDR 残留路由验收通过\n'
