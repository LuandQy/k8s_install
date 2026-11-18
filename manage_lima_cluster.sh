#!/usr/bin/env bash
# ==============================================================================
# manage_lima_cluster.sh - Lima 3-Node Heterogeneous K8s Cluster Orchestrator
# Compatible with macOS default /bin/bash (Bash 3.2+) and modern Linux Bash
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PUB_KEY_FILE=""
if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    PUB_KEY_FILE="$HOME/.ssh/id_rsa.pub"
elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    PUB_KEY_FILE="$HOME/.ssh/id_ed25519.pub"
else
    echo "[ERROR] No SSH public key found in ~/.ssh/ (expected id_rsa.pub or id_ed25519.pub)" >&2
    exit 1
fi
HOST_PUB_KEY="$(cat "$PUB_KEY_FILE")"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64|aarch64)
        LIMA_ARCH="aarch64"
        UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/releases/jammy/release-20261020/ubuntu-22.04-server-cloudimg-arm64.img"
        UBUNTU_IMAGE_DIGEST="sha256:e720ae083f93baae47ac9b76a096243fe1027f60998cf1127a47a74c880f64ed"
        ;;
    x86_64|amd64)
        LIMA_ARCH="x86_64"
        UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/releases/jammy/release-20261020/ubuntu-22.04-server-cloudimg-amd64.img"
        UBUNTU_IMAGE_DIGEST="sha256:2099e63da0b822ef8e05e3d596c1b402eaaae658fc08ab919cb8495bfcdc488b"
        ;;
    *)
        echo "[ERROR] Unsupported host architecture: $HOST_ARCH" >&2
        exit 1
        ;;
esac

get_node_cpus() {
    case "$1" in
        k8s-node1) echo 4 ;;
        k8s-node2|k8s-node3) echo 2 ;;
    esac
}

get_node_mem() {
    case "$1" in
        k8s-node1) echo "5GiB" ;;
        k8s-node2|k8s-node3) echo "3GiB" ;;
    esac
}

get_node_sys_disk() {
    case "$1" in
        k8s-node1) echo "30GiB" ;;
        k8s-node2|k8s-node3) echo "10GiB" ;;
    esac
}

NODES=("k8s-node1" "k8s-node2" "k8s-node3")

generate_lima_yaml() {
    local node="$1"
    local cpus="$(get_node_cpus "$node")"
    local mem="$(get_node_mem "$node")"
    local sys_disk="$(get_node_sys_disk "$node")"
    local data_disk="${node}-data"
    local yaml_file="/tmp/lima-${node}.yaml"

    cat <<EOF > "$yaml_file"
vmType: vz
os: Linux
arch: ${LIMA_ARCH}
images:
  - location: "${UBUNTU_IMAGE_URL}"
    arch: "${LIMA_ARCH}"
    digest: "${UBUNTU_IMAGE_DIGEST}"
cpus: ${cpus}
memory: ${mem}
disk: ${sys_disk}
networks:
  - vzNAT: true
additionalDisks:
  - name: "${data_disk}"
    format: false
    mount: false
provision:
  - mode: system
    script: |
      #!/usr/bin/env bash
      set -eux

      # 1. Clean conflicting /etc/hosts entries (e.g. 127.0.1.1) and set hostname
      hostnamectl set-hostname "${node}" || hostname "${node}"
      sed -i '/127\.0\.1\.1/d' /etc/hosts

      # 2. Configure SSH root access and password
      echo "root:Test@123456" | chpasswd
      sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
      sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
      mkdir -p /etc/ssh/sshd_config.d
      sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
      sed -i 's/KbdInteractiveAuthentication no/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
      printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' > /etc/ssh/sshd_config.d/01-root.conf
      systemctl restart ssh || systemctl restart sshd || true

      # 3. Inject host public key
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      echo "${HOST_PUB_KEY}" >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys

      # 4. Configure passwordless sudo
      echo "root ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-root-nopasswd
      chmod 440 /etc/sudoers.d/99-root-nopasswd

      # 5. Format and mount 20GB data disk to /data
      ROOT_DISK=\$(findmnt -n -o SOURCE / | sed 's/p[0-9]*\$//; s/[0-9]*\$//')
      DATA_DEV=""
      for dev in \$(lsblk -dpno NAME,TYPE | awk '\$2=="disk"{print \$1}'); do
        if [ "\$dev" != "\$ROOT_DISK" ]; then
          DATA_DEV="\$dev"
          break
        fi
      done

      if [ -n "\$DATA_DEV" ]; then
        if ! blkid "\$DATA_DEV" | grep -q 'TYPE="ext4"'; then
          mkfs.ext4 -F "\$DATA_DEV"
        fi
        mkdir -p /data
        UUID=\$(blkid -s UUID -o value "\$DATA_DEV")
        if ! grep -q "\$UUID" /etc/fstab && ! grep -q "/data" /etc/fstab; then
          echo "UUID=\$UUID /data ext4 defaults 0 2" >> /etc/fstab
        fi
        mount -a || true
        mountpoint -q /data || mount "\$DATA_DEV" /data || true
        chmod 755 /data
      fi

      # 6. Setup persistent vzNAT peer route via host gateway 192.168.64.1
      GW=\$(ip route show default | grep lima0 | awk '{print \$3}' || true)
      [ -n "\$GW" ] || GW="192.168.64.1"
      SUBNET=\$(ip -o -4 addr show dev lima0 | awk '{print \$4}' | cut -d/ -f1 | sed 's/\.[0-9]*$/.0\/24/' || true)
      [ -n "\$SUBNET" ] || SUBNET="192.168.64.0/24"
      printf 'network:\n  version: 2\n  ethernets:\n    lima0:\n      routes:\n        - to: %s\n          via: %s\n          on-link: true\n          metric: 50\n' "\$SUBNET" "\$GW" > /etc/netplan/60-lima-onlink.yaml
      chmod 600 /etc/netplan/60-lima-onlink.yaml
      netplan apply || true
      ip route replace "\$SUBNET" via "\$GW" dev lima0 onlink || true

      # 7. Pre-install dependencies to avoid offline blocking
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y || true
      apt-get install -y socat conntrack ipset ebtables ipvsadm tar iptables nfs-common chrony busybox-static nfs-kernel-server jq util-linux openssh-client sshpass python3-openpyxl || true
EOF
    echo "$yaml_file"
}

cmd_destroy() {
    echo "=================================================================="
    echo " [DESTROY] Tearing down Lima cluster and deleting all data disks..."
    echo "=================================================================="
    for node in "${NODES[@]}"; do
        echo "--> Stopping and deleting instance: $node"
        limactl stop -f "$node" 2>/dev/null || true
        limactl delete -f "$node" 2>/dev/null || true
        echo "--> Deleting data disk: ${node}-data"
        limactl disk delete -f "${node}-data" 2>/dev/null || true
        rm -f "/tmp/lima-${node}.yaml"
    done
    rm -f "$SCRIPT_DIR/.cluster_ips"

    # Clean known_hosts of any old node keys
    if [ -f "$HOME/.ssh/known_hosts" ]; then
        echo "--> Cleaning up host ~/.ssh/known_hosts..."
        for node in "${NODES[@]}"; do
            ssh-keygen -R "$node" 2>/dev/null || true
        done
        for i in $(seq 2 20); do
            ssh-keygen -R "192.168.64.$i" 2>/dev/null || true
        done
    fi
    echo "[OK] Destroy completed. All resources freed."
}

cmd_up() {
    echo "=================================================================="
    echo " [UP] Creating and initializing 3-node Lima cluster..."
    echo " Host Architecture: $HOST_ARCH (Guest: $LIMA_ARCH)"
    echo " Total RAM: 11 GiB (node1=5G, node2=3G, node3=3G)"
    echo "=================================================================="

    # 1. Create independent 20GiB disks
    for node in "${NODES[@]}"; do
        local disk="${node}-data"
        if ! limactl disk list 2>/dev/null | awk '{print $1}' | grep -qx "$disk"; then
            echo "--> Creating 20GiB disk: $disk"
            limactl disk create "$disk" --size 20GiB
        else
            echo "--> Disk $disk already exists"
        fi
    done

    # 2. Serial launch of the 3 VMs
    for node in "${NODES[@]}"; do
        local yaml_file
        local cpus="$(get_node_cpus "$node")"
        local mem="$(get_node_mem "$node")"
        local sys_disk="$(get_node_sys_disk "$node")"
        yaml_file="$(generate_lima_yaml "$node")"
        echo "--> Starting instance: $node ($cpus vCPUs, $mem RAM, $sys_disk sys disk + 20G data disk)..."
        limactl start --name="$node" --tty=false "$yaml_file"
    done

    echo "=================================================================="
    echo " All instances started. Gathering IP addresses and verifying..."
    echo "=================================================================="

    local node1_ip=""
    local node2_ip=""
    local node3_ip=""

    for node in "${NODES[@]}"; do
        local ip=""
        for attempt in $(seq 1 15); do
            ip="$(limactl shell "$node" ip -4 -o addr show dev lima0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
            if [ -n "$ip" ]; then
                break
            fi
            sleep 2
        done
        if [ -z "$ip" ]; then
            echo "[ERROR] Failed to obtain vzNAT IP for $node" >&2
            exit 1
        fi
        case "$node" in
            k8s-node1) node1_ip="$ip" ;;
            k8s-node2) node2_ip="$ip" ;;
            k8s-node3) node3_ip="$ip" ;;
        esac
        echo "--> $node: $ip"
        ssh-keygen -R "$ip" 2>/dev/null || true
    done

    # Save IPs
    cat <<EOF > "$SCRIPT_DIR/.cluster_ips"
NODE1_IP=$node1_ip
NODE2_IP=$node2_ip
NODE3_IP=$node3_ip
EOF

    local ips=("$node1_ip" "$node2_ip" "$node3_ip")

    # 3. Configure peer onlink routes on each node to ensure互通 (bypassing bridge private isolation)
    for ip in "${ips[@]}"; do
        echo "--> Ensuring routing on $ip..."
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@$ip" \
            "GW=\$(ip route show default | grep lima0 | awk '{print \$3}'); if [ -n \"\$GW\" ]; then SUBNET=\$(ip -o -4 addr show dev lima0 | awk '{print \$4}' | cut -d/ -f1 | sed 's/\.[0-9]*$/.0\/24/'); ip route replace \"\$SUBNET\" via \"\$GW\" dev lima0 onlink; fi"
    done

    # 4. Verify SSH and /data capacity on all nodes
    echo "=================================================================="
    echo " Verifying SSH, /data capacity, and inter-node connectivity..."
    echo "=================================================================="
    for i in 0 1 2; do
        local node="${NODES[$i]}"
        local ip="${ips[$i]}"
        echo "--> Checking $node ($ip):"
        local data_size
        data_size="$(ssh -o StrictHostKeyChecking=no "root@$ip" "df -h /data | awk 'NR==2{print \$2}'")"
        echo "    /data mount capacity: $data_size"
        if [[ "$data_size" != *"G"* ]]; then
            echo "[ERROR] /data capacity is unexpected: $data_size on $node" >&2
            exit 1
        fi
    done

    # 5. Check mutual ping and mutual SSH between all nodes
    for src_ip in "${ips[@]}"; do
        for dst_ip in "${ips[@]}"; do
            if [ "$src_ip" != "$dst_ip" ]; then
                echo "--> Testing $src_ip -> $dst_ip:"
                ssh -o StrictHostKeyChecking=no "root@$src_ip" "ping -c 2 -W 2 $dst_ip" >/dev/null
                echo "    Ping: OK"
                ssh -o StrictHostKeyChecking=no "root@$src_ip" "nc -zv -w 2 $dst_ip 22" >/dev/null 2>&1
                echo "    Port 22 reachable: OK"
            fi
        done
    done

    echo "=================================================================="
    echo " [SUCCESS] 3-Node Lima Cluster Ready!"
    echo " k8s-node1: $node1_ip"
    echo " k8s-node2: $node2_ip"
    echo " k8s-node3: $node3_ip"
    echo "=================================================================="
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    case "${1:-}" in
        up)
            cmd_up
            ;;
        destroy)
            cmd_destroy
            ;;
        *)
            echo "Usage: $0 {up|destroy}" >&2
            exit 1
            ;;
    esac
fi
