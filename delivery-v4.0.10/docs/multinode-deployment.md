# 多节点部署与恢复边界

多节点同样优先使用 `sudo bash deploy.sh` 的“安装”菜单，完整流程会按组件范围处理所有声明节点；无需因节点数量增加而改为手工分步部署。向导和 env 使用方法见 [交互式一键部署指南](deploy-guide.md)。

本说明适用 20261114-r5。现场前置和已验证范围见 [部署前置条件手册](deployment-checklist.md)，配置文件路径与读取身份见 [配置衔接说明](configuration-workflow.md)。外部仓库配置参考 [external-harbor.env](../examples/external-harbor.env)。

## 配置与执行顺序

保留默认 `REGISTRY_MODE=harbor`、`CLUSTER_VERIFY_MODE=selected-node`、空 `SSH_KNOWN_HOSTS`，原有单节点配置继续可解析。下列选项必须显式配置：

| 配置 | 含义与约束 |
| --- | --- |
| `REGISTRY_MODE=external-harbor` | 仅 `COMPONENTS=k8s`，外部仓库不进入受管节点清单 |
| `HARBOR_ADDRESS` | 外部仓库 IPv4；不得与受管节点、Pod/Service 网段或 API 入口重叠 |
| `HARBOR_CA` | 已核对来源的公开 PEM CA；禁止混入私钥；仅 HTTPS |
| `CLUSTER_VERIFY_MODE=cross-node` | 至少两个 K8s 节点；目前要求同架构；PVC 仍只验收首控制节点 |
| `SSH_KNOWN_HOSTS` | 绝对路径的预先固定公钥文件；内容摘要进入快照和工作流指纹 |

外部仓库模式的 `NODES` 只写本次受管节点，不能包含外部 Harbor 主机或 `registry` 角色；`HARBOR_CERT/HARBOR_KEY/HARBOR_VIP` 留空。控制端须事先正确解析 Harbor 域名，安装器只检查解析，不修改控制端 hosts。受管节点 hosts、CoreDNS、NodeLocalDNS 使用显式地址；新建集群生成独立 CA，不能将 Harbor 的公开 CA 冒充集群根 CA。

先按实际导出/向导路径定义 CONFIG，由有权读取文件的身份用同一份完整配置运行 `config-check`、`plan` 与 `render` 审查（示例地址、CA、离线制品路径必须替换）。外部仓库配置从模板准备，使用 `sudo bash deploy.sh --env /path/to/external-harbor.env`，选择“安装 → 使用已有配置范围 → 复用”；当前新建向导面向受管 Harbor，不用于重新生成外部仓库配置。

完整流程会自动按下列顺序执行，通常不必手工逐条启动：

```text
access → prepare → deps → services-init → services-verify
       → images-verify → k8s-install → node-images-verify → cluster-verify → ledger
```

这是外部 Harbor 的顺序。镜像和公开项目须已存在；`harbor-install`、`harbor-projects`、`images-import` 会在工作流/节点操作前被拒绝。受管 Harbor 的主路径见 [交互式一键部署指南](deploy-guide.md)，阶段细节见 [高级分步执行参考](staged-install.md)。不能把旧集群或完整运行目录复制为新集群身份，也不能为了绕过阻塞而更换 `STATE_DIR`。

## SSH 信任边界

先从可信控制台获取公钥，核对节点身份及 IP 后写入专用 known_hosts；不要将未经核验的 ssh-keyscan 输出直接作为信任来源。设置后，shell 接入、上传、向导探测使用严格验证，禁用全局 known_hosts、用户 SSH 配置和自动更新。文件缺失、为空或快照摘要变化时拒绝连接。空值保持既有 accept-new 行为，不等于严格固定信任。

固定交付的 KubeKey v4.0.10 内部 SSH connector 不支持主机公钥验证。每次部署、扩容、重置或镜像导入的 KK 调用前，安装器额外通过严格 OpenSSH 检查公钥和基线 machine-id/UUID，保存 `kk-ssh-preflight.json`；其中明确记录 `kk_host_key_verification=unsupported`、`connection_window_eliminated=false`。这不能消除 KK 随后自行连接的窗口；需要端到端严格校验的生产环境不能据此前置检查宣称已经满足要求。

## 中断恢复

先保留运行目录、错误日志、原停止锁及已成功阶段，不因 SSH 失联就重做 prepare 或重启机器。恢复可观测性并核对 I/O、身份、磁盘和内存后，才评估原阶段续跑。具体规则：

- kubelet unit 已安装但 `/etc/kubernetes/kubelet.conf` 不存在或为空，不算已加入集群；已加入节点仍检查 `LoadState=loaded` 及服务状态。
- kubeadm token 只接受 6 位小写字母/数字、点、16 位小写字母/数字。stderr 单独保存在节点私有目录 `/etc/kubekey/rise/kubeadm-token-create.stderr`，避免 KK 合并输出把警告写入 token；命令非零退出和非法输出仍停止。
- 首装仍拒绝网段重叠。续跑只允许精确匹配本集群 Service CIDR 的已有路由，且必须同时通过部署标记和路由归属核验；其他网段、默认路由、重复路由或实际网关/设备/协议/metric 改变都拒绝。
- 路由归属记录 `/etc/kubekey/rise/service-route.json` 必须是 root 所有、不可由组/其他人写入的普通文件，文件及父目录不得为符号链接。schema=1，包含 `deployment_id/destination/gateway/device/protocol/metric`，protocol 必须 static，metric 为正整数，并与 main 表唯一匹配路由一致。核验脚本不创建记录、不添加路由。只可由现场网络方案与可信部署身份核对后另行建立记录，不能给未知路由补标签来消除冲突。
- reset playbook 的提权/defaults 范围限 `k8s_cluster/etcd`；独立 registry-only/NFS-only 主机不属于目标。实际 reset 仍清理受管 K8s/etcd，必须按原预览与确认流程执行，共享宿主网络和证书删除影响见 [维护手册](operations.md)，实际操作必须另行审查。

**旧回执兼容性：**源码修订会改变项目和工作流指纹。直接拿新源码对旧集群执行 resume/扩容/维护可能被指纹保护拒绝；需保留原源码、原工作目录和原回执，针对具体维护操作审查兼容性。禁止直接重写 fingerprint、删除 state 或重新 prepare 来绕过。

## 验收与监控

cross-node 验收每个声明 K8s 节点的 DNS、API/Harbor 严格 TLS，并对每个有向异节点对验证 Pod IP、Service IP 和 Service FQDN 的相同文件 SHA256。三节点为 6 个有向对、18 条路径。节点 UID/IP/架构、Ready/压力和逐节点已验收镜像摘要均核验；缺少任一路径或节点证据，台账不能标完整。

本地 PVC 仅验证首控制节点同节点 Pod 重建；不代表所有节点存储、节点重启、容量配额、HA 或 NFS 已验收。成功只按 UID 回收本次资源并等待正常 PV/目录回收；失败保留现场，不强制删 finalizer 或目录。

阶段内置 I/O 监测只覆盖执行控制节点，其余节点明确列在 `io_guard.unmonitored_nodes`。长安装需要外部监督器同时持续读取宿主与全部 VM/节点的新内核日志；基线应区分历史错误，监控失联也必须停止后续安装，不能视为无错误。VM 实验要求宿主 MemAvailable 至少 4 GiB，新 I/O 错误、内存低于阈值或监控失联时停止安装进程组、保存进度与错误，并仅对明确归属的目标 VM 采取保护动作。全节点监督器须由接收方按现场环境准备并验证，通用安装器不会自动建立这项监督。

## 适用与限制

已完成实机覆盖的组合为 Ubuntu 24.04 amd64、单控制平面加两个 worker、外部 HTTPS Harbor，包含各节点 CRI 摘要、跨节点 DNS/TLS/Service 与首控制节点同节点 PVC 重建。这不证明其它系统/架构组合、HA、NFS PVC、所有节点存储或重启恢复已经通过，也不代表接收方环境当前健康。

正式入口为 `bash deploy.sh`；不要把历史原生 playbook 当作部署/删除替代入口。例如 `playbooks/delete_nodes.yaml` 引用的旧角色不是本交付支持的操作路径。完整前置与验收边界见 [部署前置条件手册](deployment-checklist.md)，维护操作见 [维护手册](operations.md)。内部测试、VM 现场和历史材料不随用户包交付。
