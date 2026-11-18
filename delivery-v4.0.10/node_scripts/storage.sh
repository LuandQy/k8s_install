#!/usr/bin/env bash
# Parameters: mode path device confirmation harbor_source roles
# Read-only probe: filesystem-check path (does not require root).
set -euo pipefail
die() { echo "[ERROR] $*" >&2; exit 1; }
check_runtime_filesystem() {
    local path="$1" probe="$1" fs options mount_root details
    [[ "$path" = /* ]] || die '文件系统检查需要绝对路径'
    # An existing data mount may contain a not-yet-created application directory.
    # Resolve its nearest existing ancestor without creating anything.
    while [ ! -e "$probe" ]; do probe="$(dirname "$probe")"; done
    fs="$(findmnt -n -o FSTYPE -T "$probe")" || die "无法识别 $path 的文件系统"
    options="$(findmnt -n -o OPTIONS -T "$probe")" || die "无法读取 $path 的挂载选项"
    case ",$options," in *,ro,*) die "$path 位于只读文件系统，不能作为运行时数据盘";; esac
    case "$fs" in
        ext4) ;;
        xfs)
            command -v xfs_info >/dev/null || die "$path 使用 XFS，但缺少 xfs_info，无法证明 ftype=1；请先离线准备 xfsprogs 并核验"
            mount_root="$(findmnt -n -o TARGET -T "$probe")" || die "无法识别 $path 的 XFS 挂载点"
            details="$(xfs_info "$mount_root" 2>&1)" || die "XFS ftype 核验失败（${mount_root}）：$details"
            [[ "$details" =~ (^|[[:space:],])ftype=1([[:space:],]|$) ]] || die "$path 的 XFS 未证明 ftype=1，不能作为运行时数据盘；请核验 xfs_info 输出"
            ;;
        *) die "$path 的文件系统为 ${fs:-未知}，不支持作为 Docker/containerd/Harbor 数据盘；仅支持 ext4 或已验证 ftype=1 的 XFS，不会转换或格式化现有文件系统";;
    esac
    printf '[OK] 运行时数据盘文件系统：%s（%s）\n' "$fs" "$path"
}
if [ "${1:-}" = filesystem-check ]; then
    [ "$#" -eq 2 ] || die '用法：storage.sh filesystem-check /绝对路径'
    check_runtime_filesystem "$2"
    exit 0
fi
mode="$1"; target="$2"; device="$3"; confirmation="$4"; harbor_source="$5"; roles=",$6,"
test "$(uname -s)" = Linux && test "$(id -u)" -eq 0 || die '需要 Linux root'
native_check() {
    local minimum="${7:-20}" available path unit
    [[ "$minimum" =~ ^[1-9][0-9]{0,4}$ ]] || die '根分区空间阈值无效'
    available=$(df -Pk / | awk 'NR==2{print $4}')
    [[ "$available" =~ ^[0-9]+$ ]] && [ "$available" -ge "$((minimum*1024*1024))" ] || die "根分区可用空间不足，至少需要 ${minimum} GiB"
    check_native_dir() {
        local path="$1" unit="$2"
        [ ! -L "$path" ] || die "$path 已有软链接，请人工处理"
        if [ -e "$path" ]; then
            test -d "$path" && test -z "$(ls -A "$path")" || die "$path 已有数据，请人工处理"
        fi
        [ ! -e "/etc/systemd/system/$unit.service.d/rise-data.conf" ] || die "$unit 已有数据盘挂载依赖，请人工处理"
        systemctl is-active --quiet "$unit" && die "$unit 正在运行，请人工处理"
        return 0
    }
    if [[ "$roles" = *,registry,* ]]; then check_native_dir /var/lib/docker docker; check_native_dir "$harbor_source" harbor; fi
    if [[ "$roles" = *,control_plane,* || "$roles" = *,worker,* ]]; then check_native_dir /var/lib/containerd containerd; check_native_dir /var/lib/kubelet kubelet; fi
    printf '[OK] native 模式：跳过软链接，保留原生数据目录；根分区可用 %s GiB（最低 %s GiB）\n' "$(awk -v kib="$available" 'BEGIN{printf "%.1f",kib/1024/1024}')" "$minimum"
}
if [ "$mode" = native-check ]; then native_check "$@"; exit 0; fi
# Fail before creating a target directory, acquiring a writable lock, or linking
# component data. A mounted exFAT/NTFS disk is not a Linux runtime data volume.
if [ "$mode" = existing ]; then check_runtime_filesystem "$target"; fi
for c in findmnt lsblk blkid wipefs flock; do command -v "$c" >/dev/null || die "缺少 $c"; done
exec 9>/run/lock/rise-deploy-storage.lock
flock -n 9 || die '其他磁盘准备进程正在运行'
if [ "$mode" = native ]; then
    native_check "$@"
    mkdir -p /etc/kubekey/rise
    printf 'native\n' > /etc/kubekey/rise/storage-mode
    exit 0
fi
[[ "$target" = /* && "$target" != / && "$target" != *'..'* ]] || die '数据目录无效'
mkdir -p "$target"
root_dev="$(findmnt -n -o MAJ:MIN -T /)"

# Refuse existing component data before any partition or mount mutation.
precheck_link() {
    local src="$1" dst="$2" unit="$3"
    if [ -L "$src" ]; then
        test "$(readlink -m "$src")" = "$(readlink -m "$dst")" || die "$src 指向其他位置，请人工处理"
    elif [ -e "$src" ] && [ "$src" != "$dst" ]; then
        test -d "$src" && test -z "$(ls -A "$src")" || die "$src 已有数据，请人工处理"
    fi
    if [ ! -L "$src" ] && [ -d "$dst" ] && [ -n "$(ls -A "$dst")" ]; then
        die "$dst 已有数据且未建立对应链接，请人工处理"
    fi
    systemctl is-active --quiet "$unit" && die "$unit 正在运行，请人工处理"
    return 0
}
if [[ "$roles" = *,registry,* ]]; then
    precheck_link /var/lib/docker "$target/docker" docker
    precheck_link "$harbor_source" "$target/harbor" harbor
fi
if [[ "$roles" = *,control_plane,* || "$roles" = *,worker,* ]]; then
    precheck_link /var/lib/containerd "$target/containerd" containerd
    precheck_link /var/lib/kubelet "$target/kubelet" kubelet
fi

empty_disk() {
    test -b "$device" || die '所选设备不是块设备'
    test "$(lsblk -dn -o TYPE "$device")" = disk || die '仅允许整盘创建 GPT'
    test "$(lsblk -dn -o RO "$device" | xargs)" = 0 || die '只读设备'
    test "$(lsblk -nr -o NAME "$device" | wc -l | xargs)" = 1 || die '设备已有分区或映射'
    test -z "$(lsblk -dn -o FSTYPE "$device")" || die '设备已有文件系统'
    test -z "$(wipefs -n --noheadings -o TYPE "$device")" || die '设备存在数据签名'
    test -z "$(lsblk -dn -o MOUNTPOINT "$device")" || die '设备已挂载'
    test "$(lsblk -dn -o MAJ:MIN "$device")" != "$root_dev" || die '拒绝系统盘'
    local name
    name="$(basename "$(readlink -f "$device")")"
    test -z "$(ls -A "/sys/class/block/$name/holders")" || die '设备正在被 LVM/RAID/映射占用'
    ! swapon --noheadings --raw --show=NAME | grep -qxF "$device" || die '设备用于 swap'
}
fstab_target_exists() {
    awk -v p="$target" '$0 !~ /^[[:space:]]*#/ && $2==p {found=1} END{exit !found}' /etc/fstab
}

if [ "$mode" = format ]; then
    for c in parted partprobe udevadm mkfs.ext4; do command -v "$c" >/dev/null || die "缺少 $c"; done
    mountpoint -q "$target" && die '目标已经挂载，不允许格式化覆盖'
    test -z "$(ls -A "$target")" || die '目标目录非空，禁止挂载遮蔽数据'
    ! fstab_target_exists || die 'fstab 已有目标路径，请人工检查'
    empty_disk
    size="$(lsblk -bdn -o SIZE "$device" | xargs)"
    expected="FORMAT:$device:$size"
    test "$confirmation" = "$expected" || die '格式化确认内容不匹配'
    # Recheck after confirmation, immediately before the destructive action.
    empty_disk
    parted -s "$device" mklabel gpt
    parted -s "$device" mkpart primary ext4 1MiB 100%
    partprobe "$device"
    udevadm settle
    partition="$(lsblk -nrpo NAME,TYPE "$device" | awk '$2=="part"{print $1}')"
    test "$(printf '%s\n' "$partition" | wc -l | xargs)" = 1 && test -b "$partition" || die '分区识别失败'
    mkfs.ext4 "$partition"
    uuid="$(blkid -s UUID -o value "$partition")"
    test -n "$uuid" || die '未获得 UUID'
    mount "UUID=$uuid" "$target"
    if ! fstab_target_exists; then
        cp -a /etc/fstab "/etc/fstab.rise.$(date +%s).bak"
        printf 'UUID=%s %s ext4 defaults 0 2\n' "$uuid" "$target" >> /etc/fstab
        printf '[OK] 已写入 /etc/fstab: UUID=%s %s ext4 defaults 0 2\n' "$uuid" "$target"
    else
        die 'fstab 已存在该路径条目，请人工检查，保留当前挂载'
    fi
    findmnt --verify --tab-file /etc/fstab
    echo '[OK] /etc/fstab 持久挂载配置验证通过'
elif [ "$mode" != existing ]; then
    die '必须选择 format 或 existing'
fi

data_dev="$(findmnt -n -o MAJ:MIN -T "$target")"
test "$data_dev" != "$root_dev" || die '选择的目录仍位于根分区，请选择其他大容量挂载盘'
findmnt -T "$target" -o TARGET,SOURCE,FSTYPE,SIZE,AVAIL
mount_root="$(findmnt -n -o TARGET -T "$target")"
test "$mount_root" != / || die '未找到独立数据盘挂载点'
findmnt --fstab --target "$mount_root" >/dev/null || die '现有数据盘未配置持久挂载，请人工配置 fstab 后重试'

link_dir() {
    local src="$1" dst="$2" unit="$3"
    mkdir -p "$dst"
    if [ "$src" != "$dst" ]; then
        if [ -L "$src" ]; then
            test "$(readlink -f "$src")" = "$(readlink -f "$dst")" || die "$src 指向其他位置，请人工处理"
        elif [ -e "$src" ]; then
            test -d "$src" && test -z "$(ls -A "$src")" || die "$src 已有数据，请人工处理"
            systemctl is-active --quiet "$unit" && die "$unit 正在运行"
            rmdir "$src"
            ln -s "$dst" "$src"
        else
            mkdir -p "$(dirname "$src")"
            ln -s "$dst" "$src"
        fi
    fi
    mkdir -p "/etc/systemd/system/$unit.service.d"
    printf '[Unit]\nRequiresMountsFor=%s\n' "$dst" > "/etc/systemd/system/$unit.service.d/rise-data.conf"
    echo "[OK] $src -> $dst"
}
if [[ "$roles" = *,registry,* ]]; then
    link_dir /var/lib/docker "$target/docker" docker
    link_dir "$harbor_source" "$target/harbor" harbor
fi
if [[ "$roles" = *,control_plane,* || "$roles" = *,worker,* ]]; then
    link_dir /var/lib/containerd "$target/containerd" containerd
    link_dir /var/lib/kubelet "$target/kubelet" kubelet
fi
systemctl daemon-reload
mkdir -p /etc/kubekey/rise
printf 'existing\n' > /etc/kubekey/rise/storage-mode
