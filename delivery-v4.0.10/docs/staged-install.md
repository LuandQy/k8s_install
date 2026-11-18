# 高级分步执行参考

正常首装优先使用 `sudo bash deploy.sh`，通过菜单“安装”完成配置确认后自动串联全流程；操作主线见 [交互式一键部署指南](deploy-guide.md)。本文供高级用户定位阶段、检查前置依赖和排障，不要求普通用户逐条执行全部阶段。多节点部署也可一次启动完整流程。

新环境首装与既有集群维护必须区分，已有回执先审查代码兼容性；已 reset 的集群不能复用旧阶段成功记录运行 all/install。多节点、外部 Harbor 及恢复边界见 [多节点部署说明](multinode-deployment.md)。公共发行不包含现场运行记录、证书或 VM 配置。

## 命令及执行边界

`bash deploy.sh` 是统一入口。无参数进入菜单；“安装”执行完整工作流，“分步部署”提供下面的高级操作。单独阶段使用 `bash deploy.sh <阶段> --env <同一份配置>`，与完整流程共用执行逻辑和状态保护。先按 [配置衔接说明](configuration-workflow.md) 明确 CONFIG 路径及读取身份；sudo 生成的私有文件由管理员读取，不能放宽权限。

| 阶段 | 前置成功记录 | 执行动作 |
| --- | --- | --- |
| preflight | 无 | 本机只读预检、离线介质核对和隔离 APT 模拟，生成配置草案/计划/阻塞清单 |
| bootstrap | 无 | 控制端离线 jq、flock、SSH 工具；密码接入加 `--with-sshpass` |
| config-check / plan | 可信配置 | 只读静态配置校验/计划；支持 --json，不连接节点、不发布阶段成功 |
| render / check | 配置 | 本地配置预览 / 节点环境检查；会生成本地运行报告 |
| access | 无 | 全部声明节点 SSH/sudo/身份检查；bootstrap 全通过后分发公钥；key/password 不分发 |
| prepare（init 别名） | access | 完整准备范围的存储、内核初始化，不再重复 SSH 初始化 |
| deps | prepare | 离线 OS 依赖；新 NFS 节点包含服务端软件包；禁止 online 回退 |
| services-init | prepare、deps | NTP 配置/同步验收、可选 NFS 配置/挂载读写验收 |
| services-verify | services-init | 重验时间同步、受管配置及 NFS 挂载读写；不改服务配置 |
| harbor-install | prepare、deps、services-init、services-verify | 重验基础服务后仅安装 Harbor |
| harbor-projects | prepare + 仓库在线 | 创建所需公开项目；已有私有项目报错 |
| images-import | prepare、harbor-projects | 控制端 KubeKey playbook 上传选定镜像，随即核验 |
| images-verify | prepare + 仓库在线 | 项目、标签、摘要、架构、实例/VIP 一致性验收 |
| k8s-install | prepare、deps、services-init、services-verify、images-verify | 再验基础服务、镜像、身份后安装 K8s，不上传镜像 |
| node-images-verify | k8s-install、services-verify | 再验 Harbor；每个 K8s 节点通过 CRI 按标签拉取全部选定镜像，检查实际摘要 |
| cluster-verify | k8s-install、services-verify、images-verify、node-images-verify | 首个控制节点上创建临时 Pod，验收 DNS/API 与 Harbor TLS/Service/可选本地 PVC 重建，成功后按 UID 回收 |
| ledger | 无 | 本地生成 XLSX/JSON/HTML/CSV；前置未完成则生成草稿，不连接节点、不要求密码或 root |
| verify | 已安装组件 | 保留原集群/Harbor 健康检查 |
| install | prepare、deps、services-init | 组合验收、安装及台账阶段，不自动初始化 |
| all / resume | 原配置 | 从 access 开始组合，跳过成功的修改阶段，重验服务、仓库、节点拉取及集群功能，再生成台账 |

每条命令均使用 `bash deploy.sh <阶段> --env 同一份配置`。加 `--debug`（等价 `--log-level debug`）可输出 DEBUG、命令追踪与失败位置；日志不脱敏，只在受控终端使用。`ledger --output 新目录` 可指定导出位置。控制端台账生成需要 **Python 3.7+ 标准库**，不需要 pip 或额外表格库；all/install/resume 在开始前检查此条件。现有 bootstrap 离线包不含 Python，非预装 Python 的控制端须先准备对应系统的离线包。

K8s 范围的完整顺序为 `access → prepare → deps → services-init → services-verify → harbor-install（按范围）→ harbor-projects/images-import（按范围）→ images-verify → k8s-install → node-images-verify → cluster-verify → ledger`。当前功能阶段严格验收 HTTPS Harbor；包含 K8s 的 `all/install/resume/cluster-verify` 遇到 `HARBOR_HTTP=true`，会在创建运行记录、安装或修改节点之前拒绝。仅 Harbor 的 HTTP 流程仍可执行，不将 HTTP 成功记录为 TLS 通过。

`prepare` 负责 Shell 存储/内核准备。KubeKey 仍负责主机名、sysctl、模块及 K8s 组件；分步安装通过 `rise.os_prepared=true` 跳过 native/repository、native/ntp 和 native/nfs，避免重复安装依赖或覆盖已验收配置。单独使用原生 playbook 的行为保留。

KubeKey 二进制为 v4.0.10，并已合入其模板侧修复（etcd 备份变量、证书续期单元、卸载清理、keepalived VRID、依赖安装退出码、containerd static 归档、kubeadm 有效期）。离线制品仍由 v4.0.9 导出；回退与验收边界见 [KubeKey v4.0.10 评估](kubekey-4.0.10.md)。

`all --components harbor --skip-image-import` 完成基础服务、Harbor 和范围内台账；`all --components k8s` 不安装 Harbor、不推镜像。先 Harbor 后 K8s 时使用同一份完整配置，仅用 CLI 改变范围。Web 部署固定调用 `all --non-interactive`，按表单范围顺序执行对应阶段；不提供任意分步、resume、reset 或扩容接口。手工分阶段操作仍使用 CLI。

## 本机只读预检和错误进度

```bash
bash deploy.sh preflight --output /srv/rise-evidence/preflight-new
# 可仅探测本机；此时离线依赖会明确标为“未核实”
bash deploy.sh preflight --host-only --output /srv/rise-evidence/host-only-new
```

`preflight` 在读取集群配置之前进入，使用 Python 标准库。读取磁盘拓扑、稳定标识、挂载、已有文件条目数、运行时状态/数据量、地址和路由、端口、时间服务；不会运行 SSH、安装器、挂载、格式化或 Docker 清理。它不是部署阶段成功回执，也不会替代 access/prepare。普通用户可以运行；受限环境或权限不足标记 unknown，不将 Docker 拒绝访问时输出的零值当作真实数量。需要补全这些信息时，在有权限的主机终端用 sudo 执行同一命令和新的输出目录。

离线检查流式读取归档并只解出检查所需的小文件，使用已有 `7z` 读取 ISO，不挂载 ISO。核对归档 SHA256、选定版本二进制/chart/ISO 路径、OCI manifest 摘要与引用、软件包索引与 deb 内容；APT 使用输出目录内的独立配置、包状态副本、file: 包源和 `--simulate`。不会改 `/etc/apt`、`/var/lib/apt`、系统 dpkg 状态或服务。缺少检测工具时标为未核实，不自动联网补装。`--kubernetes` 可选择随包版本；默认值从 configs/v*.yaml 的最高版本自动发现。

分别报告本机节点依赖、本机可选 NFS 服务端、控制端含 sshpass、组合依赖和空 dpkg 状态解析。前四项成功只证明当前主机基础包上的离线解析通过，不证明维护脚本、内核或实际服务运行成功；空状态诊断用来揭示介质对基础 OS 的依赖，比全新 Ubuntu 基础系统更严格。当前介质依赖基础 OS 已有 tar/Python 等工具，接收方须逐项核对，不能认为它包含全新系统的完整依赖闭包。不要把“本地源能解析”写成“已经完成安装验收”。

输出 `preflight-report.md/html`、`report.json`、每项命令的 stdout/stderr 和 `checks.json`。进度包含项目、退出码、耗时、具体失败原因；返回码 0 表示当前选定方案无已知阻塞（仍有说明的验证边界），2 表示阻塞或未核实，1 表示检测器异常。已有输出目录拒绝覆盖。`--offline-report 已有report.json` 可以合并同项目/版本的证据，明确标记复用；证据过期或缺少输入指纹则需重新完整检测。

受限环境可能看不到真实 netlink、systemd 或磁盘权限；会标记受限上下文，不将沙箱只读挂载当作主机真实只读。包括 `ss` 在报 netlink 权限错误后仍返回 0 的情况，也不会判为通过。需要在受限环境先生成规划文件时，可显式加 `--node-ip 规划IPv4`；未被本机采集证实的地址仍是 unknown，不能消除安装阻塞。复用证据会核对介质大小/修改时间与当前 dpkg 状态摘要，报告明确没有重新计算全部介质摘要；完整审计才重新扫描归档。

生成的配置将 master/worker/Harbor 放在 node1，单节点使用 local 连接，不需要先配置本机 SSH 免密；NFS 默认关闭。完全离线假设下，明确配置 node1 本地 chrony 时间源，需核对机器时间；存在现场 NTP 时应改为 external。当前本机安装 chrony 的 APT 计划会替换 systemd-timesyncd，实际切换必须经过服务初始化和验收。

两份配置分别使用 native 原生目录和 existing 独立数据盘。后者为待准备草案，不直接选择任何块设备。exFAT/NTFS 不可作为本项目容器数据盘；XFS 必须实测 ftype=1，ext4 还需核验独立挂载、fstab 和已有数据。新增数据盘不会绕过现有 Docker/containerd 数据保护。

若已完成 `storage.sh existing` 存储准备，预检会读取 existing 标记、Docker/containerd/kubelet/Harbor 四个组件软链接，验证它们指向同一独立可写 Linux 数据盘，并匹配 fstab 的 UUID/设备。通过后主方案为 `data-disk`，输出 `all-in-one-data-disk.env` 和 `plan-data-disk.txt`，使用实际数据根（例如 `/data/rise-data`）；此时 native 因已有软链接而不可直接使用。缺失或不一致的标记、链接、挂载仍会阻止安装，不自动修复。

集群 `check` 同步增加每节点 6 个检查阶段和心跳，生成 `reports/checks.json` 与 `reports/checks.csv`，记录阶段、状态、退出码、耗时、错误摘要和节点日志路径（摘要不做脱敏）。SSH、sudo、JSON 解析、扩展检查失败也会保留报告；原 `summary.json/csv` 字段兼容保留。

`preflight` 同时生成 `runtime-report.json/md/html`，列出 Docker 全部容器（包括停止状态）、镜像、卷、bind 源目录、数据占用，以及发现的 containerd 实例、命名空间、任务和快照。只读取所需字段，不导出容器环境变量/启动参数/Labels、卷驱动 Options 或仓库凭据；缺权限、工具或失败项记 unknown，不自动安装工具。以 root 运行可以补齐受保护目录，但成功读取不会解除已有运行时接管保护。

已卸载运行时需要单独证明：相关客户端与守护进程程序均不存在、服务和 Docker socket 不活跃、无守护进程或 socket、无遗留运行配置，且默认数据根不存在或可读且为空。以管理权限证明这些条件后，清单标为 `not_installed`（不适用），不会伪造容器/镜像数量为零。程序缺失但目录有数据、无法读取目录或仍有运行配置时，继续保留 unknown/阻塞。运行时包发生变化后必须重新审计离线依赖，旧 dpkg 状态的结果不能直接复用。

Docker 使用 containerd image store 时，镜像数据可能主要位于 `/var/lib/containerd`，不能只统计 `/var/lib/docker`。Docker 镜像逻辑大小、构建缓存、containerd content/snapshot 和父子目录可能重叠，不直接求和；Reclaimable 不代表允许清理。0 个 Docker 本地卷也不代表没有 bind 挂载的宿主机数据。生成的配置注释和计划带上本次运行时摘要与实际阻塞项，禁止因容器全部停止而误认为可以直接首装。

## SSH 接入

`SSH_AUTH_MODE=bootstrap`：先用已有部署密钥测试，失败时使用节点第13列引用的密码环境变量；全节点登录、sudo 和身份均通过后才分发公钥。没有指定变量名的 bootstrap 节点可用 `RISE_SSH_PASSWORD`。首次连接记录主机密钥，已知主机密钥变化仍拒绝。

`SSH_AUTH_MODE=key`：只使用 `SSH_KEY`，不分发密钥。`password`：每次 SSH、文件上传以及 KubeKey inventory 都使用第13列引用的密码；不分发密钥，不修改 sshd。普通用户仍需 `sudo -n`。交互模式隐藏读取密码；无人值守需预先通过进程环境提供。新建环境必须已有一种可用的 SSH 登录方式，本工具不绕过首次接入条件。

`render` 中密码统一为占位符；实际 inventory 含运行所需密码，权限为 0600，不能作为普通交付附件。环境台账只输出白名单字段。私钥、密码和完整配置不会写入台账。

## NTP 和 NFS

- `NTP_MODE=existing`：保留现场 chrony 配置，仍检查服务与同步状态。`external`：使用逗号分隔的 `NTP_SERVERS`。`node`：通过 `NTP_NODE` 选择一个声明节点，先配置服务端，再配置其余节点为客户端；客户端必须同步到该节点。
- `node` 没有上游时必须显式配置 `NTP_ALLOW_LOCAL=true`；只提供集群内部时间基准，不保证 UTC 准确。服务端检查本地参考 ID `7F7F0101`、空参考源名称、stratum 10、正常闰秒状态和剩余校时量，记录 `local_unreferenced`；不使用要求外部同步的 `waitsync` 验收此模式。客户端和有上游的模式仍须通过 `waitsync` 及相应的选中源检查。默认最大剩余校时量 `NTP_MAX_CORRECTION=0.5` 秒，单节点最多等待约40秒。不会强制执行 makestep；时间误差过大时停止，留给运维处理。
- 新配置先由 `chronyd -p` 检查；原主配置备份一次到 `.before-rise-集群名`，受管配置标记集群归属。同步/配置漂移失败阻止安装，恢复配置须显式重跑 `services-init`。服务端仅允许声明节点 IP 访问。
- `NFS_MODE=none/existing/new`。new 的 Ubuntu 服务端需要 `nfs-kernel-server`，Kylin 需要 `nfs-utils`，由 deps 使用同一离线源安装；介质缺包或依赖不完整即失败，不联网补包。原归档未重新制包，不能据代码支持推断介质已具备全部 NFS 依赖。
- new 写入 `/etc/exports.d/rise-集群名.exports`；保留其他导出配置，目标路径存在非受管导出时拒绝。使用 root_squash，限制客户端为声明节点 IP 和 Pod CIDR。仅新建共享根目录设置 `NFS_ANON_UID/GID`（默认65534）和0770权限，不递归改动已有数据权限。
- 验收用临时挂载和唯一临时文件测试读写；默认 `NFS_VERSION=4`，可选3。探测挂载使用 soft/timeo 与 timeout 控制失败时长，不写 fstab；结束清除本次文件并卸载，卸载失败报错保留现场。该探测不决定业务挂载参数，也不替代 CSI/PVC 或 CAMP 应用 UID/GID 权限验收。

Chrony 检查依据：[chronyc waitsync/tracking](https://chrony-project.org/doc/latest/chronyc.html)。

## 先 Harbor、后 K8s，同一节点复用

第一步就声明完整未来拓扑：例如同一行写 `control_plane,worker,registry`。保留同一份原配置、CLUSTER_NAME、STATE_DIR 和 WORK_DIR。使用 CLI 的 `--components` 改变执行范围，不编辑原配置切换范围。

```bash
# 在 delivery-v4.0.10 目录中。以下为新环境首装示例；已有部署应先核对回执和代码兼容性。
CONFIG=/srv/rise-config/site-new.env
sudo bash deploy.sh access --env "$CONFIG"
sudo bash deploy.sh prepare --env "$CONFIG"
sudo bash deploy.sh deps --env "$CONFIG"
sudo bash deploy.sh services-init --env "$CONFIG"
sudo bash deploy.sh services-verify --env "$CONFIG"
sudo bash deploy.sh harbor-install --env "$CONFIG"
sudo bash deploy.sh harbor-projects --env "$CONFIG"
sudo bash deploy.sh images-import --env "$CONFIG"
sudo bash deploy.sh images-verify --env "$CONFIG"
sudo bash deploy.sh k8s-install --env "$CONFIG"
sudo bash deploy.sh node-images-verify --env "$CONFIG"
sudo bash deploy.sh cluster-verify --env "$CONFIG"
sudo bash deploy.sh ledger --env "$CONFIG"
```

也可分两段：`all --components harbor` 完成仓库及镜像，然后 `all --components k8s`。第一段会为已声明的全部未来节点提前准备目录与 OS 依赖。这是刻意的行为：Harbor 的 Docker 也会使用 containerd，不能启动 Harbor 后再把同机 containerd 目录当成空目录重做初始化。

第二段复用同一个生效快照；不再经过旧 prepared 索引的组件范围匹配。Docker/Harbor/containerd 的运行状态只有在受管 Harbor 回执、CA 和节点身份均匹配后才可放行。给一台机器写 registry 角色不代表可以接管它现有的 Docker 服务。

外部已有仓库的 `--components k8s` 可以只准备 K8s 节点。若已有仓库与 K8s 同机、却没有本工具仓库归属证据，仍然拒绝接管运行时。要在第一段完成后再新增拓扑、迁移存储或换版本，不能靠改配置绕过快照：应先走明确的扩容或重建方案。

## 两种存储方案

- `examples/all-in-one-native.env`：保留系统盘原生目录，数据设备字段为空，不分区、格式化或迁移目录。
- `examples/all-in-one-nvme-existing.env`：新 NVMe 先人工确认为目标盘、挂载到 `/data` 并配置 fstab，再选 existing。脚本复用独立挂载，按照原有逻辑建立组件数据目录链接；不会自动处理已有非空 Docker/containerd 数据。

磁盘容量不能决定设备名，样例不预填格式化设备。实际设备身份、现有文件系统和空间需在目标环境通过 preflight 与现场核对确认。静默 prepare 只允许 native/existing；auto/format 仍要求真实人工确认，不能用 -y 绕过。

## 状态、验收和恢复

新状态位于 `${STATE_DIR}.workflow/`，每阶段记录 pending/running/succeeded/failed、时间、运行目录和配置/执行代码指纹；接入、准备、基础服务及镜像验收证据保存摘要，后续复用会检查。文件原子替换、权限受 umask 077 保护；初始化快照和机器身份分别保存摘要。阶段失败不会发布 succeeded，安装前再次核验机器身份、存储准备和依赖能力。

实际 Harbor/K8s 安装继续使用原部署回执、节点归属标记、PKI、配置与制品摘要检查。K8s 安装失败后重复 `k8s-install` 或 `resume` 会进入原 installer 的 resume 校验，不自动重做存储，也不重装已经成功的 Harbor。若实际初始化已经开始后中断，会停止并要求先人工核对挂载/日志，避免自动重复格式化；尚未进入初始化脚本的前置失败允许修复后重试。

项目/镜像阶段可显式重跑修复删除的项目或镜像。重新导入前，旧 images-verify 成功标记和受管 Harbor 的 images_ready 会先失效；导入失败仍不能继续 K8s。只有单独 images-verify 真正通过后，才更新 images_ready 并绑定版本、验收文件路径和摘要。

镜像证据失效、重跑节点拉取或服务初始化也会使 `cluster-verify` 变为 pending。该阶段和服务/镜像验收一样，每次请求都会实际重验，不只复用此前 succeeded；功能证据绑定文件 SHA256，失败不会发布成功记录。

每次安装前会再次检查镜像，即使磁盘上有先前成功记录。验收支持单架构 manifest 的 extra_attrs 和多架构 index 的 references；空目标、空平台、无效摘要、缺镜像/架构、私有项目和认证失败均拒绝。证据 `images-evidence.json` 保存 repository、tag、digest、platforms、target，不保存密码。

仓库摘要检查证明各实例/VIP 的同名标签内容一致，不宣称已经与离线源的预期 digest 做独立比对。新增 node-images-verify 在 K8s 安装后使用 `/etc/crictl.yaml` 中的 CRI 配置按标签拉取，核对 inspecti 的 repoDigests；接受验收过的 index 摘要或该节点架构对应的子 manifest 摘要。凭据/证书信任由运行时配置承担，不跳过 TLS 验证。缓存全部保留，因此不宣称完成冷缓存全量下载或镜像启动测试。镜像平台使用完整声明拓扑中的架构集合，不再因“仅部署 Harbor”就硬编码导入双架构。

安装成功、但进程在写阶段成功记录前被杀死的极小窗口，会保留“已完成安装回执”并拒绝自动重装，要求核对两套记录。状态损坏、配置/代码变化同样停止；不要手工删除状态来重试。旧版已部署环境不会自动迁移到新 journal；继续使用旧维护入口，并保留匹配版本代码。reset 后明确要求 redeploy，不能把旧成功阶段当作新集群已安装。

## 集群功能验收

`bash deploy.sh cluster-verify --env 同一份配置` 由首个声明的控制平面节点执行；节点须匹配已记录的集群身份、IP 和架构，并处于 Ready、无压力状态。默认 `CLUSTER_VERIFY_MODE=selected-node` 只验收首控制节点。设为 `cross-node` 时，功能探针覆盖所有声明为 control_plane/worker 的节点，并校验每个有向异节点对；至少需要两个节点，目前要求它们具有相同 CPU 架构。原 `verify` 仍用于基础健康检查；`cluster-verify` 会创建和删除自身测试资源，不属于只读操作。

前置需要控制端和执行节点已有 Python 3，执行节点已有 kubectl、journalctl、findmnt、ip、OpenSSL、curl 及其动态加载器/运行库、ldd，以及包含 httpd 的静态 BusyBox。诊断镜像 `openebs/linux-utils:4.3.0` 必须已经过仓库和该节点架构的 CRI 验收，运行时按已验收 digest 固定。脚本检查并复制已有工具，不联网下载或安装软件包；缺依赖时带具体阶段/错误停止。这些依赖不能据本机通过就推定已包含在全新 OS 的离线介质中。

测试 Pod 使用独立命名空间、非 root 用户，不挂载 hostPath、不使用特权或宿主机网络，也不自动挂载 ServiceAccount token。Pod 只取得公开 CA 和工具，不接收 Harbor 密码、管理员 kubeconfig、客户端证书或私钥；API 与 Harbor 探测不带认证凭据，关闭代理和用户 curl 配置，严格验证 CA/域名，并检查错误 CA 确实返回 curl 60。专用阶段无需 Harbor 密码。

真实验收包含：

- 使用 Pod 默认解析器、其 nameserver 及 CoreDNS Service 查询 Kubernetes 标准域名、Harbor 和配置的 API 别名，核对地址并拒绝回环等不可用结果；验证 API 标准域名/别名的 HTTPS 版本及 Harbor HTTPS 健康响应。
- 同一选定节点上的服务 Pod 与客户端，通过 PodIP、Service ClusterIP 和 Service 域名读取同一随机文件并核对 SHA256。
- `LOCAL_STORAGE=true` 时使用 OpenEBS hostpath 动态 PVC，核对 PVC/PV UID、节点约束及 `LOCAL_PATH` 下本次目录的真实挂载身份。原服务 Pod 按 UID 删除后重建，使用同一 PVC，不重写文件，核对宿主机与重建前后文件 SHA256，并重复 Service 访问。1 GiB 是申请量，不代表验证了配额强制执行；未测试主机重启或故障切换。
- `LOCAL_STORAGE=false` 时以 emptyDir 完成 Service 验收，PVC/持久性明确记录为 skipped 并附原因；不因此声称 NFS PVC 已验收。

`cross-node` 模式复用首控制节点的测试服务，并在其他 K8s 节点各创建一个 emptyDir 探针及独立 Service。每个节点分别验收 DNS、API 与 Harbor 严格 TLS；每个有向异节点对分别通过 Pod IP、Service IP、Service 域名获取同一目标文件并核对 SHA256。三个节点应有 6 个有向对、18 条 HTTP 路径。实际 Pod nodeName、节点 UID、IP、Ready/压力及各节点诊断镜像摘要均须匹配。PVC 持久性仍只在首控制节点进行；`network_all_nodes_verified=true` 不表示所有节点存储、重启恢复或 HA 已通过。

跨节点模式中，阶段内核 I/O 监测仍限于首控制节点，其他节点写入 `io_guard.unmonitored_nodes`，不会冒充已实时监测。需要所有机器遇新 I/O 错误立即停止的现场，应由操作监督器同时监测宿主及各节点；现场监督器必须另行准备并验证。跨节点台账必须同时具备所有节点 DNS/TLS 证据、完整有向对和三条通信路径，缺少任一项即为不完整。

全部检查通过后，先核对资源归属，再以 UID 前置条件回收本次 Pod、Service、ConfigMap、PVC 和命名空间；由存储控制器正常回收对应 PV/目录，并验证原有 PV 保留。不直接删除数据目录、不强制移除 finalizer，镜像缓存始终保留。前序检查失败时保留已创建资源；若清理中途失败，保留剩余资源、已完成操作与失败证据，不发布完整通过状态。

阶段日志和 `cluster-verify-evidence.json` 保存进度、失败阶段、具体错误、节点及远端证据目录；新 I/O 错误触发立即停止后续动作，不继续清理或安装。I/O 监测范围是选定执行节点。修复后重跑使用新隔离资源，遗留资源须根据失败证据和 UID 单独核对处理。

## 环境台账

`ledger` 可以在任意时点导出规划与已有记录，生成 **9 张表**：环境概览、主机清单、网络与服务规划、NTP与NFS验收、磁盘与挂载、节点镜像验收、集群功能验收、执行记录和待核对事项。功能表展示 DNS/TLS/Service/PVC、清理和 I/O 结果及所选节点/验证边界。计划值、实际准备的存储策略以及受管集群回执中的版本/节点值分别保存；磁盘信息标记为 prepare 前的观察值，不当作当前实时状态。

只有当前范围所需阶段、证据摘要及集群回执均有效时，状态才为 `recorded_checks_passed`；K8s 范围新增校验 `cluster-verify` 的 schema、验证范围、各项检查、清理完成和无新增 I/O 错误，PVC 结果须与 `LOCAL_STORAGE` 一致。未完成、配置漂移、证据缺失/篡改、清理未完成、reset 或未完成扩容标为 `draft_or_incomplete`。生成台账不刷新现场健康状态，`live_health_checked=false`；故障后可独立导出草稿，all/install/resume 在最终功能验收通过后自动导出。发行包不包含接收方部署成功记录，不能据其他环境的台账判断当前集群健康。

XLSX 使用纯文本单元格，CSV 防止公式注入，HTML 转义内容；磁盘快照仅导出白名单字段，不导出可能包含凭据的挂载选项。数据库密码和 CAMP 初始化信息没有自动填成已验证，平台部署仍属后续范围。

## 使用范围

阶段成功只证明本次记录的检查范围；配置、代码、环境或目标变化后须重新审查。静态计划、台账和本地状态不代替实时健康与接收方签收。无权读取回执时 status 会显示状态未知并返回非零，不能据此首装。

已有实机范围、离线依赖闭包限制、KubeKey 主机公钥窗口及 HA/NFS PVC/重启恢复等未覆盖项见 [部署前置条件与验收边界](deployment-checklist.md)。首装以 [交互式指南](deploy-guide.md) 为主，既有集群操作按 [维护手册](operations.md) 先备份和审查。测试方法与运行记录由交付方独立保管，不作为接收方操作材料。
