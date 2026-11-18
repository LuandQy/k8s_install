#!/usr/bin/env bash
# Back up / restore preparation metadata around the KubeKey uninstall role.
set -euo pipefail
action="$1"; backup="$2"; token="$3"; roles=",$4,"; purge="$5"
[[ "$backup" =~ ^/[a-zA-Z0-9_./-]+$ && "$backup" != *..* && "$backup" = */rise-reset-backups/reset-* ]] || exit 1
[[ "$token" =~ ^[a-zA-Z0-9-]+$ ]] || exit 1
case "$action" in
 backup)
    [ "$(cat /etc/kubekey/rise/deployment-id)" = "$token" ]
    [ ! -e "$backup" ] && [ ! -L "$backup" ]
    # Reject symlink ancestors before creating a backup directory.
    probe="$backup"; while [ "$probe" != / ]; do [ ! -L "$probe" ]; probe=$(dirname "$probe"); done
    mkdir -p "$backup"; chmod 700 "$backup"
    cp -a /etc/kubekey/rise "$backup/node-markers"
    cp -a /etc/fstab "$backup/fstab"
    for f in /etc/etcd.env /etc/systemd/system/etcd.service; do [ ! -f "$f" ] || cp -a "$f" "$backup/"; done
    if [[ "$roles" = *,etcd,* ]]; then
        [ ! -L /var/lib/etcd ] || { echo 'etcd 数据目录是软链接，需人工核对'; exit 1; }
        if systemctl is-active --quiet etcd; then
            ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/ssl/etcd/ssl/ca.crt --cert=/etc/ssl/etcd/ssl/server.crt --key=/etc/ssl/etcd/ssl/server.key --command-timeout=60s snapshot save "$backup/etcd-snapshot.db" > "$backup/snapshot.log" 2>&1
            test -s "$backup/etcd-snapshot.db"
        elif [ -d /var/lib/etcd ]; then
            size=$(du -sk /var/lib/etcd | awk '{print $1}')
            free=$(df -Pk "$backup" | awk 'NR==2{print $4}')
            [ "$free" -gt "$((size + 102400))" ] || { echo 'etcd 备份空间不足'; exit 1; }
            tar -czf "$backup/etcd-data.tgz" -C /var/lib etcd
            tar -tzf "$backup/etcd-data.tgz" > /dev/null
        fi
    fi
    printf '[OK] 节点备份: %s\n' "$backup"
    ;;
 restore)
    test -d "$backup/node-markers"
    mkdir -p /etc/kubekey/rise
    cp -a "$backup/node-markers/." /etc/kubekey/rise/
    [ "$(cat /etc/kubekey/rise/deployment-id)" = "$token" ]
    cmp /etc/fstab "$backup/fstab"
    # Upstream reset flushes iptables. Docker must rebuild its networking rules.
    if [[ "$roles" = *,registry,* ]]; then
        systemctl restart docker
        systemctl restart harbor
    fi
    ;;
 verify)
    ! systemctl is-active --quiet kubelet
    if [[ "$roles" = *,etcd,* ]]; then
        ! systemctl is-active --quiet etcd
        if [ "$purge" = true ] && [ -d /var/lib/etcd ]; then test -z "$(ls -A /var/lib/etcd)"; fi
    fi
    if [[ "$roles" = *,registry,* ]]; then systemctl is-active --quiet harbor; fi
    cmp /etc/fstab "$backup/fstab"
    printf '[OK] K8s/etcd 已卸载，Harbor 与挂载保留\n'
    ;;
 *) exit 1;;
esac
