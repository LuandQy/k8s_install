#!/usr/bin/env bash
#
# env_check.sh - 节点详细采集；多节点分发由 check.sh 统一执行
#
# 背景适配:
#   面向 Linux 基础环境，使用 KubeKey 离线包部署 Kubernetes，并在其上交付智算产品
#   (AI大模型训练/推理平台、vLLM/Triton/Megatron/DeepSpeed、多卡SXM/NVLink、RDMA/RoCE高性能网络)。
#
# 用法一: 单机采集与体检(在目标节点上直接跑)
#   sudo bash env_check.sh [--network-probe] [--data-path /data]
#
# 用法二: 多节点批量采集(在跳板机/控制端跑)
#   bash check.sh --env cluster-vars.env --extended
#   或 bash env_check.sh --batch cluster-vars.env
#   批量清单统一使用 cluster-vars.env，SSH_PARALLEL 控制并发数。
#   远程报告按本次运行隔离，输出 JSON、CSV 和逐节点日志。
#
# 核心检查能力:
#   1. 基础环境与包管理器: OS发行版、内核、内部/私有源配置核查、常用工具包可用性检测
#   2. CPU / 内存 / 大页内存(HugePages): 核心数、架构、NUMA分布、大页配置、Transparent Hugepage
#   3. 磁盘介质与存储安全: 磁盘空间、Inode剩余率(df -i)、磁盘介质类型(SSD/NVMe vs 机械盘HDD ROTA检测)、
#      xfs ftype=1检测、常用模型与数据集共享存储目录(/data, /model, NFS, CephFS等)及读写权限探测
#   4. 智算加速卡深度体检(GPU/NPU):
#      - NVIDIA GPU型号、卡数、驱动与CUDA版本、持久化模式(Persistence Mode)
#      - NVIDIA FabricManager 运行状态及驱动版本一致性检测(SXM/NVLink多卡机型生命线)
#      - GPU PCIe链路协商检测(当前速率/带宽 vs 最大能力，排查降速/金手指虚接)
#      - GPU 卡间互联拓扑(NVLink / PCIe / SYS)矩阵检测
#      - GPUDirect RDMA (nvidia-peermem / nv_peer_mem) 驱动加载检测
#      - DCGM (Data Center GPU Manager) 监控服务状态
#      - 华为昇腾 NPU (npu-smi info/info -m、HCCN算力网口配置 /etc/hccn.conf、ascend-docker-runtime)
#   5. RDMA / InfiniBand / RoCE 算力网络:
#      - ibstat / ibv_devinfo / rdma link 检测 HCA 状态(Active?)与速率(100G/200G/400G HDR/NDR)
#      - RDMA 核心模块加载 (mlx5_core, mlx5_ib, ib_uverbs, rdma_cm 等)
#      - 物理网卡与RDMA网卡 MTU 大帧(Jumbo Frame 9000)一致性检测
#   6. KubeKey 离线安装阻断项与 K8s 系统基线:
#      - /tmp 挂载属性检查(排查 noexec 致命阻断项)
#      - Sudo 免密权限 (NOPASSWD: ALL) 检测(非root用户部署前置)
#      - 关键 Limit 限制: memlock=unlimited (RDMA训练核心依赖，否则报内存注册失败)、nofile、nproc
#      - 核心内核参数: vm.max_map_count(>=262144, 向量库/ES依赖)、bridge转发、ip_forward、swappiness
#      - 安全模块: SELinux、Swap、防火墙、cgroup版本(v1/v2)、已安装基础工具(socat/conntrack/ipset等)
#   7. 时间同步与时区 (timedatectl / chrony / ntp)
#   8. 容器运行时与网络端口: containerd/docker 状态、k8s端口占用、镜像仓库配置
#   9. 交付健康度诊断总结 (Pre-flight Readiness Report): 提炼 [FAIL] 阻断项、[WARN] 风险项与 [PASS]
#  10. 机器可读的 SUMMARY_ 信息与批量汇总 CSV (支持多节点 ID 重复告警与集群隐患汇总)
#

set -uo pipefail
umask 077

# =====================================================================
# 第一部分: 单机采集逻辑 (run_local)
# =====================================================================

# BEGIN DEPENDENCY_CHECK
query_dependency_package() {
    local package="$1" output candidate rc
    REPO_STATE=UNKNOWN
    REPO_DETAIL='无法核实软件源缓存'
    if [ "$PKG_MGR" = apt ] && has_cmd apt-cache; then
        if output=$(LC_ALL=C apt-cache policy "$package" 2>/dev/null); then
            candidate=$(printf '%s\n' "$output" | awk '/^[[:space:]]*Candidate:/{print $2;exit}')
            if [ -n "$candidate" ] && [ "$candidate" != '(none)' ]; then
                REPO_STATE=INSTALLABLE; REPO_DETAIL="缓存候选 ${candidate}；尚未安装，未验证下载"
            else
                REPO_STATE=MISSING; REPO_DETAIL='当前 APT 缓存无候选；离线 ISO 需由依赖阶段另验'
            fi
        fi
    elif [ "$PKG_MGR" = yum ] && has_cmd yum; then
        # Default to cache-only: never refresh metadata or install packages.
        if [ "$NETWORK_PROBE" = true ]; then
            if ! has_cmd timeout; then REPO_DETAIL='无 timeout，跳过主动源查询'; return; fi
            rc=0; output=$(LC_ALL=C timeout 15 yum -q list available "$package" 2>&1) || rc=$?
        else
            rc=0; output=$(LC_ALL=C yum -C -q list available "$package" 2>&1) || rc=$?
        fi
        if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | awk -v pkg="$package" '$1==pkg || index($1,pkg".")==1 {found=1} END{exit !found}'; then
            REPO_STATE=INSTALLABLE; REPO_DETAIL='源中有候选；尚未安装，未验证下载'
        elif printf '%s\n' "$output" | grep -q 'No matching Packages'; then
            REPO_STATE=MISSING; REPO_DETAIL='当前源缓存未找到；离线 ISO 需由依赖阶段另验'
        fi
    fi
}

collect_dependencies() {
    local tool package
    DEP_READY=0; DEP_AVAILABLE=0; DEP_MISSING=0; DEP_UNKNOWN=0
    DEPENDENCY_ROWS=''
    # Nine node prerequisites match node_scripts/deps.sh; curl/openssl are
    # additional inspection/registry tools. NFS server exportfs is role-specific.
    for tool in socat conntrack ipset ebtables ipvsadm tar iptables mount.nfs chronyd curl openssl; do
        package="$tool"
        case "$tool" in
            conntrack) [ "$PKG_MGR" != yum ] || package=conntrack-tools;;
            mount.nfs) if [ "$PKG_MGR" = yum ]; then package=nfs-utils; else package=nfs-common; fi;;
            chronyd) package=chrony;;
        esac
        if has_cmd "$tool"; then
            REPO_STATE=READY; REPO_DETAIL=$(command -v "$tool" 2>/dev/null || printf '命令可用')
            DEP_READY=$((DEP_READY+1))
        else
            query_dependency_package "$package"
            case "$REPO_STATE" in
                INSTALLABLE) DEP_AVAILABLE=$((DEP_AVAILABLE+1));;
                MISSING) DEP_MISSING=$((DEP_MISSING+1));;
                *) DEP_UNKNOWN=$((DEP_UNKNOWN+1));;
            esac
        fi
        DEPENDENCY_ROWS="${DEPENDENCY_ROWS}${tool}|${package}|${REPO_STATE}|${REPO_DETAIL}
"
    done
    log "$(render_dependency_table)"
    if [ "$DEP_READY" -eq 11 ]; then
        add_pass '依赖命令均已预装；软件源缓存状态不影响该结论'
    else
        [ "$DEP_AVAILABLE" -eq 0 ] || add_warn "$DEP_AVAILABLE 项命令未安装，但源缓存有候选；由部署依赖阶段安装后复核"
        [ "$DEP_MISSING" -eq 0 ] || add_warn "$DEP_MISSING 项命令未安装且源缓存未找到；需检查源或准备离线依赖 ISO"
        [ "$DEP_UNKNOWN" -eq 0 ] || add_unknown "$DEP_UNKNOWN 项缺失命令的源状态无法核实"
    fi
    add_info '只检查不安装、不更新软件源；候选版本可见不代表下载或离线 ISO 依赖闭包已验证'
}

render_dependency_table() {
    local tool package state detail
    printf '\n必备及辅助工具（只检查，不安装）\n'
    printf '%-12s %-18s %-12s %s\n' '命令' '软件包' '状态' '说明'
    printf '%s\n' '------------ ------------------ ------------ --------------------------------'
    while IFS='|' read -r tool package state detail; do
        [ -n "$tool" ] || continue
        printf '%-12s %-18s %-12s %s\n' "$tool" "$package" "$state" "$detail"
    done <<< "$DEPENDENCY_ROWS"
    printf 'READY=已预装；INSTALLABLE=源中可用、待安装；MISSING=缓存未找到；UNKNOWN=无法核实\n'
}
# END DEPENDENCY_CHECK


run_local() {

# REPORT_FILE is allocated securely by the entry point.

# 健康度判定追踪列表
HEALTH_FAILS=()
HEALTH_WARNS=()
HEALTH_UNKNOWNS=()
EXT_FAILS=()
EXT_WARNS=()
CHECK_SCOPE=base

log() {
    echo -e "$1" | tee -a "$REPORT_FILE"
}

section() {
    case "$1" in '5.'*|'6.'*|'华为昇腾'*) CHECK_SCOPE=extended;; *) CHECK_SCOPE=base;; esac
    log "\n========================================"
    log "== $1"
    log "========================================"
}

add_fail() {
    if [ "$CHECK_SCOPE" = extended ]; then EXT_FAILS+=("$1"); else HEALTH_FAILS+=("$1"); fi
    log "  [FAIL][$CHECK_SCOPE] $1"
}

add_warn() {
    if [ "$CHECK_SCOPE" = extended ]; then EXT_WARNS+=("$1"); else HEALTH_WARNS+=("$1"); fi
    log "  [WARN][$CHECK_SCOPE] $1"
}

add_pass() {
    log "  [PASS] $1"
}

add_info() {
    log "  [INFO] $1"
}

add_unknown() {
    HEALTH_UNKNOWNS+=("$1")
    log "  [UNKNOWN][$CHECK_SCOPE] $1"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_if_exists() {
    local desc="$1"; shift
    if has_cmd "$1"; then
        log "--- $desc ---"
        "$@" 2>&1 | tee -a "$REPORT_FILE" || true
    else
        log "--- $desc: 未检测到命令 [$1], 跳过 ---"
    fi
}

# ------------------------- 0. 基础环境判断 -------------------------

section "0. 基础环境判断"

OS_ID=""
if [ -f /etc/os-release ]; then
    OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-}")
fi

if has_cmd yum; then
    PKG_MGR="yum"
elif has_cmd apt || has_cmd apt-get; then
    PKG_MGR="apt"
else
    PKG_MGR=""
fi

log "识别到操作系统 ID: ${OS_ID:-未知}"
log "识别到包管理器: ${PKG_MGR:-未知}"
log "当前登录用户: $(whoami) (UID: $(id -u))"

# ------------------------- 1. 软件源与网络探测 -------------------------

section "1. 检查软件源配置(是否为内部/私有源)"

check_repo_files() {
    local path="$1"
    if [ -d "$path" ] || [ -f "$path" ]; then
        log "文件/目录: $path"
        grep -H -E "^[^#]*(baseurl|deb )" $path/*.repo $path 2>/dev/null | tee -a "$REPORT_FILE" || true
    fi
}

if [ "$PKG_MGR" = "yum" ]; then
    check_repo_files "/etc/yum.repos.d"
elif [ "$PKG_MGR" = "apt" ]; then
    check_repo_files "/etc/apt/sources.list"
    if [ -d /etc/apt/sources.list.d ]; then
        for f in /etc/apt/sources.list.d/*.list; do
            [ -e "$f" ] && log "$f:" && cat "$f" | tee -a "$REPORT_FILE"
        done
    fi
fi

log "\n提示: 请核对上述 baseurl/deb 地址, 确认是否已指向交付现场的内网/私有源。"

log "\n--- 外网连通性探测(仅供参考) ---"
if [ "$NETWORK_PROBE" = true ] && has_cmd curl; then
    if curl -s -m 3 -o /dev/null -w "%{http_code}" https://www.baidu.com 2>/dev/null | grep -q "200"; then
        add_info "外网(baidu.com)可访问"
    else
        add_info "公网探测未成功，不能据此确定网络环境类型"
    fi
else
    log "公网探测未启用或 curl 不可用；--network-probe 可启用"
fi

# ------------------------- 2. 软件源可用性与基础工具检测 -------------------------

section "2. 软件源可用性与 KubeKey 离线依赖工具检测"

collect_dependencies

# ------------------------- 3. 操作系统与内核版本 -------------------------

section "3. 操作系统与内核版本"
run_if_exists "os-release" cat /etc/os-release
run_if_exists "内核版本及系统架构" uname -rm

# ------------------------- 4. CPU / 内存 / 大页内存 / 磁盘与介质 -------------------------

section "4. CPU / 内存 / 大页内存 / 磁盘与介质类型"

run_if_exists "CPU 拓扑与规格" lscpu
run_if_exists "内存概况" free -h

log "\n--- 大页内存 (HugePages) 检测 (智算推理/DPDK/高性能缓存) ---"
if [ -f /proc/meminfo ]; then
    grep -i hugepage /proc/meminfo | tee -a "$REPORT_FILE" || true
    HP_TOTAL=$(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "${HP_TOTAL:-0}" -gt 0 ]; then
        add_info "系统已配置大页内存: $HP_TOTAL 页"
    else
        add_info "系统未配置静态大页内存 (普通容器通常使用系统默认分页)"
    fi
fi
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    log "Transparent Hugepage 状态: $THP"
fi

log "\n--- 磁盘空间与 Inode 使用率 (已过滤容器/虚拟挂载点) ---"
if has_cmd df; then
    df -Th -x overlay -x tmpfs -x devtmpfs -x squashfs -x shm 2>/dev/null \
        | grep -Ev "/var/lib/docker|/var/lib/containerd|/var/lib/kubelet|/run/containerd|/run/k3s" \
        | tee -a "$REPORT_FILE" || true

    log "\n--- Inode 使用率检测 (防范海量小文件数据集占满 Inode) ---"
    df -i -x overlay -x tmpfs -x devtmpfs -x squashfs -x shm 2>/dev/null \
        | grep -Ev "/var/lib/docker|/var/lib/containerd|/var/lib/kubelet|/run/containerd|/run/k3s" \
        | tee -a "$REPORT_FILE" || true

    # 关键目录剩余空间检测 (AI 镜像大，建议 /var 留足空间)
    VAR_FREE_KB=$(df -k /var 2>/dev/null | awk 'NR==2{print $4}')
    ROOT_FREE_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    VAR_FREE_GB=$(( ${VAR_FREE_KB:-0} / 1024 / 1024 ))
    ROOT_FREE_GB=$(( ${ROOT_FREE_KB:-0} / 1024 / 1024 ))

    log "\n--- 根与 /var 空间参考（不替代实际数据目录检查） ---"
    log "/ 根目录可用空间: ${ROOT_FREE_GB} GiB"
    log "/var 可用空间: ${VAR_FREE_GB} GiB"
    if [ -d "$DATA_PATH" ]; then
        if DATA_FREE_KB=$(LC_ALL=C df -Pk "$DATA_PATH" 2>/dev/null | awk 'NR==2{print $4}') && [[ "$DATA_FREE_KB" =~ ^[0-9]+$ ]]; then
            if [ "$DATA_FREE_KB" -lt 20971520 ]; then add_warn "关注的数据目录 $DATA_PATH 所在文件系统可用空间不足 20 GiB";
            else add_info "关注的数据目录 $DATA_PATH 当前可用空间不少于 20 GiB；是否满足镜像与业务容量仍需核对"; fi
        else add_unknown "无法读取数据目录 $DATA_PATH 的可用容量"; fi
    else add_info "数据目录 $DATA_PATH 尚不存在，概览展示其父目录容量，不代表独立数据盘已准备"; fi
else
    log "未检测到 df 命令，跳过"
fi

log "\n--- 磁盘介质类型检测 (ROTA: 0=SSD/NVMe, 1=HDD机械盘) ---"
if has_cmd lsblk; then
    lsblk -d -o NAME,SIZE,ROTA,TYPE,MOUNTPOINT 2>/dev/null | awk 'NR==1 || $4=="disk"' | tee -a "$REPORT_FILE" || true
    HDD_DETECTED=0
    while read -r name rota mountpoint; do
        if [ "$rota" = "1" ] && [ -n "$mountpoint" ] && [[ "$mountpoint" =~ ^/(var)?$ ]]; then
            HDD_DETECTED=1
            add_warn "检测到关键挂载点 $mountpoint 位于机械盘 ($name, ROTA=1)！K8s etcd 与容器 IO 延迟将极高，强烈建议使用 SSD/NVMe！"
        fi
    done < <(lsblk -l -n -o NAME,ROTA,MOUNTPOINT 2>/dev/null | grep -E " /| /var" || true)
    if [ "$HDD_DETECTED" -eq 0 ]; then
        add_info "未发现根或 /var 的 ROTA=1 记录；虚拟磁盘介质及实际性能需另行确认"
    fi
fi

log "\n--- 关键目录文件系统类型与 XFS ftype 检测 ---"
for dir in / /var /var/lib/docker /var/lib/containerd; do
    if [ -d "$dir" ]; then
        FSTYPE=$(df -T "$dir" 2>/dev/null | awk 'NR==2{print $2}')
        MOUNTPOINT=$(df "$dir" 2>/dev/null | awk 'NR==2{print $NF}')
        log "$dir -> 挂载点: ${MOUNTPOINT:-未知}, 文件系统类型: ${FSTYPE:-未知}"
        if [ "$FSTYPE" = "xfs" ]; then
            if has_cmd xfs_info; then
                FTYPE_INFO=$(xfs_info "$dir" 2>/dev/null | grep -o "ftype=[01]" || echo "未知")
                log "  xfs ${FTYPE_INFO} (overlay2 要求 ftype=1)"
                if [ "$FTYPE_INFO" = "ftype=0" ]; then
                    add_fail "$dir 文件系统为 xfs 且 ftype=0，containerd/docker overlay2 将无法正常工作，必须备份重格为 ftype=1！"
                fi
            else
                log "  未检测到 xfs_info 命令，建议安装 xfsprogs 确认 ftype"
            fi
        fi
    fi
done

# ------------------------- 5. 智算加速卡深度检测 (GPU / NPU) -------------------------

section "5. 智算加速卡深度检测 (NVIDIA GPU / 华为昇腾 NPU / 其他芯片)"

NV_GPU_COUNT=0
NV_GPU_MODEL="none"
NV_DRIVER_VER="unknown"
FABRICMANAGER_STATUS="NA"

if has_cmd nvidia-smi; then
    NV_GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
    NV_DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    NV_GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^[ \t]*//')

    log "--- 检测到 NVIDIA GPU: ${NV_GPU_COUNT} 张, 型号: ${NV_GPU_MODEL}, 驱动版本: ${NV_DRIVER_VER} ---"
    nvidia-smi --query-gpu=index,name,persistence_mode,driver_version,memory.total,power.limit --format=csv,noheader 2>/dev/null | tee -a "$REPORT_FILE" || true

    # 1. 检查持久化模式 (Persistence Mode)
    PM_STATUS=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [ "$PM_STATUS" = "Enabled" ]; then
        add_pass "NVIDIA GPU 持久化模式 (Persistence Mode) 已开启"
    else
        add_warn "GPU 持久化模式未开启 (当前: ${PM_STATUS:-Disabled})，容器启动可能存在延迟，建议执行: sudo nvidia-smi -pm 1"
    fi

    # 2. 检查 NVIDIA FabricManager (SXM/NVLink 多卡机型核心依赖)
    log "\n--- NVIDIA FabricManager 服务检查 (SXM/NVLink 多卡训练生命线) ---"
    IS_SXM=0
    if echo "$NV_GPU_MODEL" | grep -qi -E "SXM|NVLink|HGX|A100|A800|H100|H800|H20|B100|B200"; then
        IS_SXM=1
    fi

    if systemctl is-active nvidia-fabricmanager >/dev/null 2>&1; then
        FABRICMANAGER_STATUS="active"
        FM_VER=$(nvidia-fabricmanager --version 2>/dev/null | head -1 || echo "unknown")
        add_pass "nvidia-fabricmanager 服务正在运行 ($FM_VER)"
        if [ "$FM_VER" != "unknown" ] && ! echo "$FM_VER" | grep -q "$NV_DRIVER_VER"; then
            add_warn "nvidia-fabricmanager 版本 ($FM_VER) 与驱动版本 ($NV_DRIVER_VER) 可能不一致，多卡通信存在隐患！"
        fi
    else
        if [ "$IS_SXM" -eq 1 ] && [ "$NV_GPU_COUNT" -gt 1 ]; then
            FABRICMANAGER_STATUS="inactive"
            add_fail "检测到多卡 SXM/NVLink 机型 (${NV_GPU_MODEL} x ${NV_GPU_COUNT})，但 nvidia-fabricmanager 服务未运行！NCCL 多卡通信将直接失败！"
        elif systemctl list-unit-files 2>/dev/null | grep -q "nvidia-fabricmanager"; then
            FABRICMANAGER_STATUS="inactive"
            add_warn "系统存在 nvidia-fabricmanager 服务但未启动"
        else
            FABRICMANAGER_STATUS="NA"
            log "未安装 nvidia-fabricmanager (若非 SXM/NVLink 机型可忽略)"
        fi
    fi

    # 3. 检查 PCIe 链路协商速率与带宽 (排查硬件降速、金手指氧化虚接)
    log "\n--- GPU PCIe 链路协商检查 (排查 PCIe 降速隐患) ---"
    PCIE_WARN=0
    PCIE_DATA=$(nvidia-smi --query-gpu=index,pci.link.gen.current,pci.link.gen.max,pci.link.width.current,pci.link.width.max --format=csv,noheader 2>/dev/null || true)
    if [ -z "$PCIE_DATA" ]; then PCIE_WARN=1; add_warn "GPU PCIe 查询失败或无数据，状态 UNKNOWN"; fi
    while IFS=',' read -r idx cur_gen max_gen cur_width max_width; do
        idx=$(echo "$idx" | tr -d ' ')
        cur_gen=$(echo "$cur_gen" | tr -d ' ')
        max_gen=$(echo "$max_gen" | tr -d ' ')
        cur_width=$(echo "$cur_width" | tr -d ' ')
        max_width=$(echo "$max_width" | tr -d ' ')
        log "GPU $idx: PCIe Gen 当前: $cur_gen (最大: $max_gen), 宽度当前: ${cur_width} (最大: ${max_width})"
        if [ -n "$cur_gen" ] && [ -n "$max_gen" ] && [ "$cur_gen" -lt "$max_gen" ] 2>/dev/null; then
            PCIE_WARN=1
            add_warn "GPU $idx 发生 PCIe 协商降速 (当前 Gen$cur_gen < 最大 Gen$max_gen)！"
        fi
        if [ -n "$cur_width" ] && [ -n "$max_width" ] && [ "$cur_width" -lt "$max_width" ] 2>/dev/null; then
            PCIE_WARN=1
            add_warn "GPU $idx 发生 PCIe 宽度缩水 (当前 x$cur_width < 最大 x$max_width)！"
        fi
    done < <(printf '%s\n' "$PCIE_DATA")
    if [ "$PCIE_WARN" -eq 0 ]; then
        add_pass "所有 GPU PCIe 链路协商均处于满血规格"
    fi

    # 4. GPU 卡间互联拓扑
    log "\n--- GPU 卡间互联拓扑 (nvidia-smi topo -m) ---"
    nvidia-smi topo -m 2>&1 | tee -a "$REPORT_FILE" || true

    # 5. GPUDirect RDMA (nvidia-peermem) 模块检测
    log "\n--- GPUDirect RDMA (nvidia-peermem) 内核模块检测 ---"
    if lsmod | grep -E "nvidia_peermem|nv_peer_mem" >/dev/null 2>&1; then
        add_pass "已加载 GPUDirect RDMA 模块 (nvidia_peermem/nv_peer_mem)"
    else
        add_info "未加载 nvidia_peermem/nv_peer_mem (若进行跨机 GPU Direct RDMA 训练需加载此模块)"
    fi

    # 6. DCGM 服务检测
    log "\n--- DCGM (Data Center GPU Manager) 监控服务状态 ---"
    if systemctl is-active nvidia-dcgm >/dev/null 2>&1; then
        add_pass "nvidia-dcgm 监控服务正在运行"
    elif systemctl is-active nv-hostengine >/dev/null 2>&1; then
        add_pass "nv-hostengine 正在运行"
    else
        add_info "DCGM 未运行 (K8s 部署 GPU Operator 或 DCGM Exporter 时通常需要)"
    fi

    # 7. nvidia-container-toolkit 与 containerd 配置检查
    run_if_exists "nvidia-container-toolkit版本" nvidia-container-cli --version
    if [ -f /etc/containerd/config.toml ]; then
        if grep -q "nvidia" /etc/containerd/config.toml 2>/dev/null; then
            add_pass "containerd 中已配置 nvidia runtime"
        else
            add_info "containerd 中未发现 nvidia runtime 配置 (智算产品部署前需配置或通过 GPU Operator 注入)"
        fi
    fi
fi

# 华为昇腾 NPU 检查
if has_cmd npu-smi; then
    section "华为昇腾 NPU 检查"
    run_if_exists "npu-smi info" npu-smi info
    run_if_exists "npu-smi 固件/芯片状态" npu-smi info -m
    if [ -f /etc/hccn.conf ]; then
        add_pass "检测到 HCCN 算力网卡配置文件 (/etc/hccn.conf)"
        cat /etc/hccn.conf | tee -a "$REPORT_FILE" || true
    else
        add_info "未检测到 /etc/hccn.conf (若使用昇腾跨机分布式训练需配置算力网口)"
    fi
    if [ -d /etc/ascend-docker-runtime.d ] || has_cmd ascend-docker-runtime; then
        add_pass "已检测到 ascend-docker-runtime"
    else
        add_info "未检测到 ascend-docker-runtime (K8s 调度昇腾 NPU 需提前配置)"
    fi
fi

run_if_exists "昆仑芯/天数智芯 (ixsmi)" ixsmi
run_if_exists "PPU 驱动 (ppu-smi)" ppu-smi

# ------------------------- 6. RDMA / InfiniBand / RoCE 算力网络 -------------------------

section "6. RDMA / InfiniBand / RoCE 算力网络检测"

RDMA_STATUS="NA"
if has_cmd ibstat; then
    run_if_exists "ibstat 状态" ibstat
    if ibstat 2>/dev/null | grep -qi "State: Active"; then
        RDMA_STATUS="Active"
        add_pass "检测到 InfiniBand/RoCE 端口处于 Active 激活状态"
    else
        RDMA_STATUS="Down"
        add_warn "检测到 RDMA 设备但端口未处于 Active 状态，请检查网线/光模块及交换机配置"
    fi
elif has_cmd ibv_devinfo; then
    run_if_exists "ibv_devinfo 状态" ibv_devinfo -v
    if ibv_devinfo 2>/dev/null | grep -qi "PORT_ACTIVE"; then
        RDMA_STATUS="Active"
        add_pass "检测到 RDMA 端口处于 PORT_ACTIVE 状态"
    fi
elif has_cmd rdma; then
    run_if_exists "rdma link 状态" rdma link
else
    log "未检测到 ibstat / ibv_devinfo / rdma 命令 (若未配置 InfiniBand/RoCE 网卡可忽略)"
fi

log "\n--- RDMA 关键内核模块加载情况 ---"
if has_cmd lsmod; then
    lsmod | grep -E "mlx5_core|mlx5_ib|ib_uverbs|ib_core|rdma_cm|rdma_ucm" | tee -a "$REPORT_FILE" || true
else
    log "未检测到 lsmod 命令，跳过模块检测"
fi

log "\n--- 网络接口 MTU 配置 (RoCE/高性能网络推荐 MTU 9000 大帧) ---"
if has_cmd ip; then
    ip -d link show 2>/dev/null | grep -E "^[0-9]+:|mtu " | tee -a "$REPORT_FILE" || true
fi

# ------------------------- 7. 主机名与网络配置 -------------------------

section "7. 主机名与网络信息"

run_if_exists "主机名" hostname
run_if_exists "hosts 文件" cat /etc/hosts

IFACE_FILTER='docker|cni|flannel|veth|br-|virbr|tunl|kube-ipvs|cali|cilium|weave|cbr0'

log "--- 网卡与 IP 信息 (已过滤虚拟网卡) ---"
if has_cmd ip; then
    ip -o addr show 2>/dev/null | grep -Ev "^[0-9]+: ($IFACE_FILTER)" | tee -a "$REPORT_FILE" || true
fi

log "\n--- 路由表 (已过滤虚拟网卡) ---"
if has_cmd ip; then
    ip route 2>/dev/null | grep -Ev "dev ($IFACE_FILTER)" | tee -a "$REPORT_FILE" || true
fi

log "\n--- DNS 配置 ---"
if [ -f /etc/resolv.conf ]; then
    grep -E "^nameserver" /etc/resolv.conf | tee -a "$REPORT_FILE" || true
fi

log "\n--- 默认路由与推荐主网卡 ---"
if has_cmd ip; then
    DEFAULT_ROUTE_LINE=$(ip route show default 2>/dev/null | head -1 || true)
    log "默认路由: ${DEFAULT_ROUTE_LINE:-未检测到默认路由}"
    MAIN_IFACE=$(echo "$DEFAULT_ROUTE_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    MAIN_IP=$(ip -o -4 addr show "${MAIN_IFACE:-lo}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
    log "推荐主网卡: ${MAIN_IFACE:-未知}, 对应IP: ${MAIN_IP:-未知}"
    log "提示: 智算机房通常分为业务网、管理网与RDMA存储/算力网，请核对该网卡是否为用于 K8s 通信的主网卡。"
fi

# ------------------------- 8. KubeKey 离线安装与 K8s 前置基线 -------------------------

section "8. KubeKey 离线安装与 K8s 系统基线检查"

# 1. /tmp noexec 检查 (高危阻断项!)
log "--- 1. /tmp 挂载属性检查 (KubeKey 致命阻断项) ---"
TMP_NOEXEC="UNKNOWN"
if TMP_OPTIONS=$(findmnt -n -o OPTIONS -T /tmp 2>/dev/null) && [ -n "$TMP_OPTIONS" ]; then
if printf '%s\n' "$TMP_OPTIONS" | tr ',' '\n' | grep -qx noexec; then
    TMP_NOEXEC="YES"
    add_fail "检测到 /tmp 挂载了 [noexec]！KubeKey 离线安装解压的二进制工具在此目录下将无法执行，安装必将失败！修复方案: mount -o remount,exec /tmp"
else
    TMP_NOEXEC="NO"
    add_pass "/tmp 未配置 noexec，符合 KubeKey 安装要求"
fi
else
    add_unknown "无法读取 /tmp 挂载属性，需核实执行权限"
fi

# 2. SELinux 状态
log "\n--- 2. SELinux 状态 ---"
if has_cmd getenforce; then
    SE_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
    log "SELinux: $SE_STATUS"
    if [ "$SE_STATUS" = "Enforcing" ]; then
        add_warn "SELinux 处于 Enforcing 状态，K8s 部署前建议设置为 Permissive 或 Disabled"
    else
        add_pass "SELinux 为 $SE_STATUS"
    fi
else
    log "未检测到 getenforce"
fi

# 3. Swap 状态 (K8s 强要求)
log "\n--- 3. Swap 状态 ---"
SWAP_STATE=UNKNOWN
if SWAP_OUTPUT=$(swapon --show 2>/dev/null); then
if [ -n "$SWAP_OUTPUT" ]; then
    SWAP_STATE=ON
    add_warn "检测到 Swap 处于启用状态！K8s 官方强烈建议关闭 Swap (swapoff -a 并在 /etc/fstab 注释)"
else
    SWAP_STATE=OFF
    add_pass "Swap 已关闭"
fi
else
    add_unknown "Swap 查询失败，不能判定已关闭"
fi

# 4. 防火墙状态
log "\n--- 4. 防火墙状态 ---"
FIREWALL_STATE=UNKNOWN
if has_cmd firewall-cmd; then
    FW_OUTPUT=$(firewall-cmd --state 2>/dev/null); FW_RC=$?
    if [ "$FW_RC" -eq 0 ] && [ "$FW_OUTPUT" = running ]; then
        FIREWALL_STATE=running; add_warn "firewalld 正在运行，请核对所需端口策略"
    elif [ "$FW_OUTPUT" = 'not running' ]; then
        FIREWALL_STATE=inactive; add_info "firewalld 未运行；仍需核对其他防火墙规则"
    else add_unknown "firewalld 状态查询失败"; fi
elif has_cmd ufw; then
    if FW_OUTPUT=$(LC_ALL=C ufw status 2>/dev/null); then
        case "$FW_OUTPUT" in
            'Status: active'*) FIREWALL_STATE=running; add_warn "ufw 正在运行，请核对端口策略";;
            'Status: inactive'*) FIREWALL_STATE=inactive; add_info "ufw 未启用；仍需核对其他防火墙规则";;
            *) add_unknown "无法识别 ufw 状态";;
        esac
    else add_unknown "ufw 查询失败，可能权限不足"; fi
else
    add_unknown "未检测到 firewalld/ufw；不能据此判断 nftables/iptables 防火墙状态"
fi

# 5. 内存锁定 (memlock) 与关键限制 Limits (RDMA 跨机训练核心依赖)
log "\n--- 5. 内存锁定 (memlock) 与句柄限制 (智算与 K8s 基础) ---"
CHECK_SCOPE=extended
MEMLOCK_VAL=$(ulimit -l 2>/dev/null || echo "unknown")
log "当前 ulimit -l (memlock): $MEMLOCK_VAL"
if [ "$MEMLOCK_VAL" = "unlimited" ]; then
    add_pass "memlock 为 unlimited (满足 RDMA 锁页内存要求)"
else
    if [ "$RDMA_STATUS" = "Active" ] || [ "$NV_GPU_COUNT" -gt 1 ]; then
        add_fail "当前 memlock 为 $MEMLOCK_VAL (非 unlimited)！RDMA 跨机训练时 NCCL 将报内存注册失败！必须在 /etc/security/limits.conf 设置 * soft/hard memlock unlimited"
    else
        add_warn "memlock 当前非 unlimited (当前: $MEMLOCK_VAL)，若后续使用 RDMA 需调整"
    fi
fi

CHECK_SCOPE=base
NOFILE_VAL=$(ulimit -n 2>/dev/null || echo 0)
log "当前 ulimit -n (nofile): $NOFILE_VAL"
if [ "${NOFILE_VAL:-0}" -ge 65535 ]; then
    add_pass "最大打开文件数 (nofile >= 65535)"
else
    add_warn "最大打开文件数较小 ($NOFILE_VAL)，建议调高至 65536 或 1048576"
fi

NPROC_VAL=$(ulimit -u 2>/dev/null || echo 0)
log "当前 ulimit -u (nproc): $NPROC_VAL"

# 6. 关键内核参数
log "\n--- 6. 关键内核参数 ---"
for p in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
    VAL=$(sysctl -n "$p" 2>/dev/null || echo "not_set")
    log "$p = $VAL"
    if [ "$VAL" != "1" ]; then
        add_warn "内核参数 $p 当前不是 1，KubeKey 安装时需配置此项"
    fi
done

VM_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo "not_set")
log "vm.max_map_count = $VM_MAP"
if [ "$VM_MAP" = "not_set" ]; then
    add_warn "无法获取 vm.max_map_count 参数 (智算平台向量库/ES 建议配置 >= 262144)"
elif [ "$VM_MAP" -lt 262144 ] 2>/dev/null; then
    add_warn "vm.max_map_count ($VM_MAP) 小于 262144，智算平台向量检索 (Milvus/Elasticsearch) 可能会启动失败！"
else
    add_pass "vm.max_map_count 符合要求 (>= 262144)"
fi

SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo "not_set")
log "vm.swappiness = $SWAPPINESS (建议 0 或 1)"

# 7. 关键内核模块与 cgroup
log "\n--- 7. 关键内核模块与 cgroup 版本 ---"
if has_cmd lsmod; then
    lsmod | grep -E "br_netfilter|^overlay|ip_vs|nf_conntrack" | tee -a "$REPORT_FILE" || true
else
    log "未检测到 lsmod 命令，跳过模块检测"
fi
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    log "cgroup: v2"
elif [ -d /sys/fs/cgroup/memory ]; then
    log "cgroup: v1"
else
    log "cgroup: 无法判断"
fi

# ------------------------- 9. 时间同步状态 -------------------------

section "9. 时间同步状态 (集群节点间时间偏差需严格一致)"

run_if_exists "timedatectl" timedatectl
run_if_exists "chronyc sources" chronyc sources
run_if_exists "ntpstat" ntpstat

TZ_RESULT=""
if has_cmd timedatectl; then
    TZ_RESULT=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
fi
if [ -z "$TZ_RESULT" ] && [ -f /etc/timezone ]; then
    TZ_RESULT=$(cat /etc/timezone 2>/dev/null || true)
fi
log "系统时区: ${TZ_RESULT:-未知}"

# ------------------------- 10. 已有容器运行时与 K8s 组件 -------------------------

section "10. 已有容器运行时与 K8s 组件检测"
RUNTIME_STATUS=""
for service in containerd docker kubelet; do
    state=$(systemctl is-active "$service" 2>/dev/null || true)
    case "$state" in active|inactive|failed|activating|deactivating) ;; *) state=UNKNOWN;; esac
    RUNTIME_STATUS="$RUNTIME_STATUS $service=$state"
done

run_if_exists "containerd 状态" systemctl status containerd --no-pager
run_if_exists "docker 状态" systemctl status docker --no-pager
run_if_exists "kubelet 版本" kubelet --version
run_if_exists "kubeadm 版本" kubeadm version
run_if_exists "crictl 版本" crictl --version

if [ -d /etc/kubernetes ]; then
    add_warn "检测到已存在 /etc/kubernetes 目录，可能此前已初始化过 K8s，若需全新部署请提前清理"
    ls -la /etc/kubernetes | tee -a "$REPORT_FILE" || true
fi

# ------------------------- 11. 常用端口占用检测 -------------------------

section "11. 常用端口占用检测 (K8s / etcd / 智算常见端口)"

# 22(SSH), 80/443(Ingress), 2379/2380(etcd), 6443(APIServer), 10250(Kubelet), 10257(KCM), 10259(Scheduler), 4789/8472(VXLAN), 111/2049(NFS)
CHECK_PORTS=(22 80 443 2379 2380 6443 10250 10251 10252 10257 10259 4789 8472 111 2049)

if has_cmd ss && SOCKETS=$(ss -lntup 2>/dev/null); then
    OCCUPIED_PORTS=()
    for port in "${CHECK_PORTS[@]}"; do
        res=$(printf '%s\n' "$SOCKETS" | grep -E ":$port\s" || true)
        if [ -n "$res" ]; then
            log "端口 $port 已被占用: $res"
            if [ "$port" != "22" ]; then
                OCCUPIED_PORTS+=("$port")
            fi
        fi
    done
    if [ ${#OCCUPIED_PORTS[@]} -gt 0 ]; then
        add_warn "检测到部分核心端口已被占用: ${OCCUPIED_PORTS[*]}，请确认是否为残留服务"
    else
        add_pass "除 SSH 22 外，核心 K8s 端口均处于空闲状态"
    fi
else
    add_unknown "ss 不可用或执行失败，无法判断端口占用"
fi

# ------------------------- 12. 共享存储与数据集挂载探测 -------------------------

section "12. 共享存储与数据集挂载探测 (智算模型资产依赖)"

run_if_exists "已配置的 NFS 导出" cat /etc/exports
log "--- 当前已挂载的网络文件系统 (NFS / Lustre / CephFS / GPFS) ---"
mount -t nfs,nfs4,lustre,gpfs,ceph 2>&1 | tee -a "$REPORT_FILE" || true

log "\n--- 智算常用共享目录存在性与写权限探测 (/data, /model, /dataset, /nfs) ---"
for sdir in /data /model /dataset /nfs /shared; do
    if [ -d "$sdir" ]; then
        TEST_FILE="$sdir/.perm_test_$$"
        if touch "$TEST_FILE" 2>/dev/null; then
            rm -f "$TEST_FILE"
            add_pass "共享目录 $sdir 存在且具备可写权限"
        else
            add_warn "共享目录 $sdir 存在但当前用户无写权限！"
        fi
    fi
done

# ------------------------- 13. 容器运行时镜像仓库配置 -------------------------

section "13. 容器运行时镜像仓库/私有源配置检测"

if [ -f /etc/docker/daemon.json ]; then
    log "--- /etc/docker/daemon.json ---"
    cat /etc/docker/daemon.json | tee -a "$REPORT_FILE" || true
fi

if [ -f /etc/containerd/config.toml ]; then
    log "--- /etc/containerd/config.toml (Registry mirrors) ---"
    grep -A4 -E "registry\.mirrors|\[plugins\..*registry\]" /etc/containerd/config.toml 2>/dev/null | tee -a "$REPORT_FILE" || true

    log "\n--- containerd SystemdCgroup 配置 ---"
    if grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
        add_pass "containerd 已配置 SystemdCgroup = true"
    else
        add_info "containerd 未明确配置 SystemdCgroup = true (KubeKey 部署时可自动生成)"
    fi
fi

# ------------------------- 14. Harbor 部署依赖检测 -------------------------

section "14. Harbor 私有镜像仓库依赖检测"

run_if_exists "docker-compose 版本" docker-compose version
run_if_exists "docker compose 插件版本" docker compose version
run_if_exists "openssl 版本" openssl version

if [ -n "${HARBOR_DOMAIN:-}" ]; then
    log "检测 Harbor 域名解析: $HARBOR_DOMAIN"
    if has_cmd getent; then
        getent hosts "$HARBOR_DOMAIN" 2>&1 | tee -a "$REPORT_FILE" || true
    fi
else
    log "未设置 HARBOR_DOMAIN 环境变量，如需检测私有镜像源域名请预先: export HARBOR_DOMAIN=harbor.example.com"
fi

# ------------------------- 15. KubeKey 离线部署前置检查 (节点唯一性 / SSH / Sudo) -------------------------

section "15. KubeKey 离线部署前置检查 (节点唯一性 / SSH / 免密Sudo)"

MID=$(cat /etc/machine-id 2>/dev/null || echo "未检测到")
PUUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "未检测到")
log "machine-id: $MID"
log "product_uuid: $PUUID"
log "(提示: 若多台节点由同一虚拟机模板克隆，易出现 ID 重复导致 K8s 节点识别异常，批量模式将自动比对)"

log "\n--- SSH 服务状态与配置 ---"
run_if_exists "sshd 运行状态" systemctl is-active sshd
if [ -f /etc/ssh/sshd_config ]; then
    grep -E "^\s*(PermitRootLogin|PubkeyAuthentication|PasswordAuthentication)" /etc/ssh/sshd_config 2>/dev/null | tee -a "$REPORT_FILE" || true
fi

if [ -f "$HOME/.ssh/authorized_keys" ]; then
    AK_COUNT=$(wc -l < "$HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
    add_pass "检测到 ~/.ssh/authorized_keys，已有公钥 $AK_COUNT 条"
else
    add_info "未检测到 ~/.ssh/authorized_keys，若使用 SSH 密钥免密登录需配置"
fi

log "\n--- Sudo 免密执行权限检测 (非 root 用户部署 K8s 核心要求) ---"
if [ "$(id -u)" -eq 0 ]; then
    add_pass "当前以 root 用户运行，具备最高权限"
else
    if sudo -n true 2>/dev/null; then
        add_pass "当前非 root 用户 ($(whoami)) 已配置免密 sudo (NOPASSWD)，符合 KubeKey 要求"
    else
        add_fail "当前非 root 用户 ($(whoami)) 未配置免密 sudo！KubeKey 远程部署在执行提权命令时将因等待输入密码而卡死！"
    fi
fi

# ------------------------- 16. 交付就绪度健康诊断总结 (Readiness Report) -------------------------

section "16. 交付就绪度健康诊断总结 (Pre-flight Readiness Report)"

OVERALL_HEALTH="PASS"
if [ "${#HEALTH_UNKNOWNS[@]}" -gt 0 ]; then OVERALL_HEALTH=WARN; fi
if [ ${#HEALTH_FAILS[@]} -gt 0 ]; then
    OVERALL_HEALTH="FAIL"
    log "\n❌ 【致命阻断项 (FAIL) - 必须在部署前修复】:"
    for item in ${HEALTH_FAILS[@]+"${HEALTH_FAILS[@]}"}; do
        log "   - $item"
    done
fi

if [ ${#HEALTH_WARNS[@]} -gt 0 ]; then
    [ "$OVERALL_HEALTH" != "FAIL" ] && OVERALL_HEALTH="WARN"
    log "\n⚠️  【高风险警告项 (WARN) - 建议排查优化】:"
    for item in ${HEALTH_WARNS[@]+"${HEALTH_WARNS[@]}"}; do
        log "   - $item"
    done
fi

if [ "$OVERALL_HEALTH" = "PASS" ]; then
    log "\n[PASS] 本次已执行的基础检查未发现异常；不替代安装及业务验收"
fi

# ------------------------- 17. 汇总关键信息 (供批量模式自动解析) -------------------------

section "17. 汇总关键信息(SUMMARY_ 开头, 供批量模式自动解析, 请勿手动修改)"

SUM_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
SUM_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "${SUM_IP:-}" ] && SUM_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')

SUM_CPU_CORES=$(nproc 2>/dev/null || echo "unknown")
SUM_MEM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')

if has_cmd getenforce; then
    SUM_SELINUX=$(getenforce 2>/dev/null || echo "unknown")
else
    SUM_SELINUX="N/A"
fi

SUM_SWAP="$SWAP_STATE"
SUM_FIREWALL="$FIREWALL_STATE"

SUM_MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")
SUM_PRODUCT_UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "unknown")

if has_cmd nvidia-smi; then
    SUM_GPU="NVIDIA"
elif has_cmd npu-smi; then
    SUM_GPU="Ascend-NPU"
elif has_cmd ixsmi; then
    SUM_GPU="Iluvatar"
elif has_cmd ppu-smi; then
    SUM_GPU="PPU"
else
    SUM_GPU="none"
fi

SUM_DOCKER_VER=$(docker -v 2>/dev/null || echo "not_installed")
SUM_KUBELET_VER=$(kubelet --version 2>/dev/null || echo "not_installed")

# 磁盘类型简要判定
SUM_DISK_TYPE="unknown"
if lsblk -d -o ROTA 2>/dev/null | grep -q "1"; then
    SUM_DISK_TYPE="HDD_Included"
fi

log "SUMMARY_HOSTNAME=${SUM_HOSTNAME}"
log "SUMMARY_IP=${SUM_IP:-unknown}"
log "SUMMARY_OS_ID=${OS_ID:-unknown}"
log "SUMMARY_KERNEL=$(uname -r 2>/dev/null)"
log "SUMMARY_ARCH=$(uname -m 2>/dev/null)"
log "SUMMARY_CPU_CORES=${SUM_CPU_CORES}"
log "SUMMARY_MEM_GB=${SUM_MEM_GB:-unknown}"
log "SUMMARY_SELINUX=${SUM_SELINUX}"
log "SUMMARY_SWAP=${SUM_SWAP}"
log "SUMMARY_FIREWALL=${SUM_FIREWALL}"
log "SUMMARY_MACHINE_ID=${SUM_MACHINE_ID}"
log "SUMMARY_PRODUCT_UUID=${SUM_PRODUCT_UUID}"
log "SUMMARY_GPU=${SUM_GPU}"
log "SUMMARY_GPU_COUNT=${NV_GPU_COUNT}"
log "SUMMARY_GPU_MODEL=${NV_GPU_MODEL}"
log "SUMMARY_FABRICMANAGER=${FABRICMANAGER_STATUS}"
log "SUMMARY_RDMA_STATUS=${RDMA_STATUS}"
log "SUMMARY_MEMLOCK=${MEMLOCK_VAL:-unknown}"
log "SUMMARY_TMP_NOEXEC=${TMP_NOEXEC}"
log "SUMMARY_DISK_TYPE=${SUM_DISK_TYPE}"
log "SUMMARY_VAR_FREE_GB=${VAR_FREE_GB:-unknown}"
log "SUMMARY_DOCKER_VER=${SUM_DOCKER_VER}"
log "SUMMARY_KUBELET_VER=${SUM_KUBELET_VER}"
log "SUMMARY_PKG_MGR=${PKG_MGR:-unknown}"
log "SUMMARY_HEALTH_RESULT=${OVERALL_HEALTH}"

log "SUMMARY_UNKNOWN_COUNT=${#HEALTH_UNKNOWNS[@]}"
log "SUMMARY_EXT_FAIL_COUNT=${#EXT_FAILS[@]}"
log "SUMMARY_EXT_WARN_COUNT=${#EXT_WARNS[@]}"
section "扩展检查与未确认项"
for item in ${EXT_FAILS[@]+"${EXT_FAILS[@]}"}; do log "  [EXT-FAIL] $item"; done
for item in ${EXT_WARNS[@]+"${EXT_WARNS[@]}"}; do log "  [EXT-WARN] $item"; done
for item in ${HEALTH_UNKNOWNS[@]+"${HEALTH_UNKNOWNS[@]}"}; do log "  [UNKNOWN] $item"; done
section "采集完成"
log "报告已保存至: $(realpath "$REPORT_FILE" 2>/dev/null || echo "$REPORT_FILE")"
overview=$(render_overview)
    printf '%s\n' "$overview" >&3
    # Keep the legacy report filename and SUMMARY_ lines for check.sh.
    report_tmp=$(mktemp "${REPORT_FILE}.XXXXXX") || return 1
    { printf '%s\n\n' "$overview"; cat "$REPORT_FILE"; } > "$report_tmp"
    mv "$report_tmp" "$REPORT_FILE"
if [ "$OVERALL_HEALTH" = FAIL ] && [ "${RISE_COLLECT_ONLY:-0}" != 1 ]; then return 2; fi

}

# =====================================================================
# 第二部分: 多节点批量采集逻辑 (run_batch)
# =====================================================================

run_batch() {
    local script_dir
    script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
    bash "$script_dir/check.sh" --env "${1:-$script_dir/cluster-vars.env}" --extended
}

# =====================================================================
# 入口: 根据参数决定走单机模式还是批量模式
# =====================================================================

render_overview() {
    printf '\n节点环境概览\n'
    printf '节点：%s    地址：%s\n' "$SUM_HOSTNAME" "${SUM_IP:-unknown}"
    printf '系统：%s / %s    内核：%s\n' "${OS_ID:-unknown}" "$(uname -m)" "$(uname -r)"
    printf '资源：%s 核 / %s GiB 内存\n' "$SUM_CPU_CORES" "${SUM_MEM_GB:-unknown}"
    printf '\n检查分类             结果与数量\n'
    printf '%s\n' '-------------------  --------------------------------'
    printf '基础检查             %s（异常 %s，提醒 %s，待核实 %s）\n' "$OVERALL_HEALTH" "${#HEALTH_FAILS[@]}" "${#HEALTH_WARNS[@]}" "${#HEALTH_UNKNOWNS[@]}"
    printf 'GPU/NPU/RDMA 扩展     GPU=%s；异常 %s，提醒 %s\n' "$SUM_GPU" "${#EXT_FAILS[@]}" "${#EXT_WARNS[@]}"
    printf '运行服务            %s\n' "$RUNTIME_STATUS"
    printf 'Swap / 防火墙        %s / %s\n' "$SUM_SWAP" "$SUM_FIREWALL"
    render_dependency_table
    printf '\n数据目录所在文件系统（不会创建目录）\n'
    for requested in / "$DATA_PATH" /var/lib/containerd /var/lib/docker /var/lib/kubelet; do
        probe="$requested"
        while [ ! -e "$probe" ] && [ "$probe" != / ]; do probe=$(dirname "$probe"); done
        if row=$(LC_ALL=C df -Pk "$probe" 2>/dev/null | awk 'NR==2 {u=$2>=1073741824?"TiB":"GiB";d=u=="TiB"?1073741824:1048576;printf "%s | %.1f %s 总计 / %.1f %s 可用 | %s",$1,$2/d,u,$4/d,u,$NF}'); then
            printf '  %s%s -> %s\n' "$requested" "$([ -e "$requested" ] || printf '（尚不存在，显示父目录）')" "${row:-UNKNOWN}"
        else printf '  %s -> UNKNOWN\n' "$requested"; fi
    done
    printf '\n需处理或核实（扩展异常不等于 K8s 安装阻断）\n'
    for item in ${HEALTH_FAILS[@]+"${HEALTH_FAILS[@]}"}; do printf '  [FAIL] %s\n' "$item"; done
    for item in ${HEALTH_WARNS[@]+"${HEALTH_WARNS[@]}"}; do printf '  [WARN] %s\n' "$item"; done
    for item in ${HEALTH_UNKNOWNS[@]+"${HEALTH_UNKNOWNS[@]}"}; do printf '  [UNKNOWN] %s\n' "$item"; done
    for item in ${EXT_FAILS[@]+"${EXT_FAILS[@]}"}; do printf '  [EXT-FAIL] %s\n' "$item"; done
    for item in ${EXT_WARNS[@]+"${EXT_WARNS[@]}"}; do printf '  [EXT-WARN] %s\n' "$item"; done
    printf '\n详细报告：%s\n' "$REPORT_FILE"
    printf '%s\n' '部署准入以 check.sh 的角色、身份、端口和 CIDR 检查为准。'
}

NETWORK_PROBE=false
DATA_PATH=${DATA_PATH:-/data}
if [ "${1:-}" = --batch ]; then shift; run_batch "$@"; exit $?; fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --network-probe) NETWORK_PROBE=true; shift;;
        --data-path) [ "$#" -ge 2 ] || { echo '--data-path 缺少路径' >&2; exit 1; }; DATA_PATH="$2"; shift 2;;
        -h|--help)
            printf '%s\n' '用法: bash env_check.sh [--network-probe] [--data-path /data]' '默认展示概要，详细报告写入 /tmp/env_report_*.log，保留 SUMMARY_* 字段。' '只展示概要，完整内容请手动查看日志；--network-probe 启用公网及 yum 源探测。' '--data-path 指定概览关注的数据目录，只查询不修改。' '批量: bash env_check.sh --batch cluster-vars.env 或 bash check.sh --extended --env cluster-vars.env'
            exit 0;;
        *) printf '未知参数: %s\n' "$1" >&2; exit 1;;
    esac
done
case "$DATA_PATH" in /*) ;; *) echo '--data-path 必须是绝对路径' >&2; exit 1;; esac
report_dir=${RISE_REPORT_DIR:-/tmp}
case "$report_dir" in /*) ;; *) echo 'RISE_REPORT_DIR 必须是绝对路径' >&2; exit 1;; esac
mkdir -p "$report_dir" || exit 1
report_dir=$(cd "$report_dir" && pwd -P) || exit 1
report_host=$(hostname | tr -c 'A-Za-z0-9._-' '_')
REPORT_FILE="$report_dir/env_report_${report_host}_$(date +%Y%m%d_%H%M%S)_$$.log"
# Refuse collisions/symlinks in shared /tmp; umask 077 keeps reports private.
(set -o noclobber; : > "$REPORT_FILE") 2>/dev/null || { echo '无法安全创建环境报告' >&2; exit 1; }
run_local 3>&1 >/dev/null 2>>"$REPORT_FILE"
