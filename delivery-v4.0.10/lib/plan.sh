#!/usr/bin/env bash
# 静态计划：调用者已加载可信现场配置；本模块不探测节点、不创建目录。
deployment_plan() {
    local row
    printf '\n=== 部署计划（配置推导，未执行现场检查）===\n'
    printf '配置：%s\n集群：%s\n范围：%s\nKubernetes：%s\nKubeKey：%s\n' "$ENV_FILE" "$CLUSTER_NAME" "$COMPONENTS" "$KUBE_VERSION" "$KK_VERSION"
    printf '\n节点与角色（同一行多角色表示复用同一节点）\n'
    while IFS= read -r row; do
        parse_node "$row"
        printf '  %s | %s | %s | %s | 数据策略=%s\n' "$NODE_NAME" "$NODE_INTERNAL" "$NODE_CONNECTION" "$NODE_ROLES" "$NODE_DATA_MODE"
        case "$NODE_DATA_MODE" in
            native) printf '    使用现有文件系统上的原生目录，不格式化、不分区、不创建组件数据软链接。\n';;
            existing) printf '    复用 %s 的独立挂载，执行时检查 fstab 和现有数据。\n' "$NODE_DATA";;
            auto|format) printf '    初始化仍需人工选择/确认设备；当前计划不授权格式化。\n';;
        esac
    done < <(active_node_lines)
    printf '\n控制端依赖：bootstrap（单独执行，需要 root）\n'
    printf '节点依赖模式：%s\n离线归档：%s\n工作目录：%s\n' "$DEPS_MODE" "${ARTIFACT_FILE:-未配置，KubeKey 可能联网获取制品}" "$WORK_DIR"
    if [ -n "$ARTIFACT_FILE" ]; then
        if [ -f "$ARTIFACT_FILE" ]; then printf '归档文件存在；本计划未核对摘要、内容或可用空间。\n'
        else printf '阻塞：配置的离线归档不存在。\n'; fi
    elif [ "$DEPS_MODE" = iso ]; then
        printf '阻塞：iso 模式必须填写 ARTIFACT_FILE 和 ARTIFACT_SHA256。\n'
    fi
    if [ -n "${PKI_ROOT_CERT:-}" ]; then
        printf '自带根 CA：%s（安装阶段由 root 校验并复制到 %s/pki）\n' "$PKI_ROOT_CERT" "$WORK_DIR"
    fi
    printf '\n常规首装：sudo bash deploy.sh → 安装；或 all --env 已核对的配置。程序自动编排阶段。\n'
    printf '\n高级分步入口（排障或专项验收；缺少前置成功记录即停止）\n'
    printf '%s\n' \
        '  access          验证全节点 SSH/sudo/身份；bootstrap 全部通过后分发公钥，也支持 key/password。' \
        '  prepare/init    一次性准备完整声明拓扑：存储、内核；要求 access 成功，共置节点提前准备全部目录。' \
        '  deps            安装准备范围内所有节点的离线 OS 依赖。' \
        '  services-init   配置指定 NTP 角色与可选 NFS；先 deps，后同步和挂载读写验收。' \
        '  services-verify 实时检查时间同步及 NFS 挂载读写；不改服务配置。' \
        '  harbor-install  仅安装 Harbor，不创建业务项目、不导入 K8s 镜像。' \
        '  harbor-projects 创建所选镜像需要的公开项目，拒绝修改已有私有项目属性。' \
        '  images-import   仅通过控制端 KubeKey 上传选定镜像，并校验标签、摘要与平台。' \
        '  images-verify   重新检查各实例/VIP 的项目、标签、摘要和所需架构，保存证据。' \
        '  k8s-install     只核验已有仓库；不隐式推镜像，不重复初始化存储或安装 OS 依赖。' \
        '  node-images-verify K8s 安装后逐节点通过 CRI 拉取镜像并检查摘要；不清理缓存。' \
        '  cluster-verify  按 selected-node/cross-node 验收 Pod DNS/API/Harbor TLS 和 Service；PVC 限首控制节点；创建并按 UID 回收临时资源，无需 Harbor 密码。' \
        '  ledger          无凭据导出 XLSX/JSON/HTML/CSV；未完成验收时标为草稿。' \
        '  verify          基础组件健康检查；cluster-verify 是独立功能验收，跨节点须显式 cross-node，HA 仍需另验。'
    printf '\nSSH 模式：%s；NTP 模式：%s；NTP 节点：%s；NTP 来源：%s；NFS 模式：%s\n' "$SSH_AUTH_MODE" "$NTP_MODE" "${NTP_NODE:-无}" "${NTP_SERVERS:-现场已有或显式本地时间源}" "$NFS_MODE"
    if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
        printf '独立 SSH 公钥文件：%s；shell 接入严格核验，文件摘要绑定快照和阶段指纹。\n' "$SSH_KNOWN_HOSTS"
        printf '能力限制：KubeKey %s 内部 SSH 不校验主机公钥；只在每次 KK 前独立 strict SSH/身份核验，不能消除 KK 连接自身窗口。\n' "$KK_VERSION"
    fi
    printf 'cluster-verify 前置：所选控制节点需 python3、curl/运行库、静态 BusyBox(httpd)、openssl、journalctl；离线 linux-utils 镜像必须已通过仓库与节点验收。\n'
    printf '功能验收模式：%s；cross-node 将覆盖声明的同架构 K8s 节点及跨节点通信，不代表 HA 故障切换。\n' "${CLUSTER_VERIFY_MODE:-selected-node}"
    if [ "$REGISTRY_MODE" = external-harbor ]; then
        printf '外部 Harbor：%s:%s -> %s；仅 HTTPS/公开 CA，仓库主机不进入 inventory，不安装、建项目或导入镜像。\n' "$HARBOR_DOMAIN" "$HARBOR_PORT" "$HARBOR_ADDRESS"
        printf '控制端域名必须已正确解析；外部模式只校验，不修改控制端 hosts。\n'
    fi
    if [ "$COMPONENTS" != harbor ] && [ "$HARBOR_HTTP" = true ]; then
        printf '阻塞：当前 cluster-verify 只验收 HTTPS Harbor；all/install/resume 会在安装前拒绝此 HTTP 配置。\n'
    fi
    printf '\n组合入口\n' 
    printf '%s\n' '  all/resume：根据 --components 选择阶段顺序，跳过已成功修改阶段，重新执行镜像验收。' \
        '  install：组合安装阶段，要求 prepare/deps/services-init 已完成；不自动初始化。' \
        '  使用同一完整配置和 STATE_DIR；--components harbor → k8s 不再切换准备快照。' \
        '  拓扑、存储或执行代码变更会阻止复用记录；prepare 中断禁止自动重做磁盘准备。'
    if [ "$REGISTRY_MODE" = ha-harbor ]; then
        printf '\nHarbor 模式：多个独立实例 + VIP %s + 镜像复制，需多机故障演练。\n' "$HARBOR_VIP"
        printf '这不证明 PostgreSQL、Redis、项目权限和存储已经具备共享一致的高可用。\n'
    fi
    printf '\n本地记录（不代表实时健康）\n'
    deployment_status "$ENV_FILE"
    printf '计划完成：没有连接节点、索取或输出安装密码、写入运行目录或启动安装。\n'
}
