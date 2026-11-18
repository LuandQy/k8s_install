# 部署前置条件与验收边界

适用交付：20261114-r5。按本清单核对后，再使用 [交互式部署指南](deploy-guide.md)。工具支持某个配置值，不等于该系统、拓扑或维护操作已经实机验证；静态计划无阻塞也不是部署许可。

## 系统、工具与接入

| 项目 | 接收方应确认 |
| --- | --- |
| 自带根 CA | 可选；同时提供自签名且 `CA:TRUE` 的根证书与无口令私钥（0400/0600），安装前由 root 校验并复制到 WORK_DIR/pki；已有集群不能中途更换 |
| WSL | 仅用于本地验证，不作为生产控制端支持范围；WSL 内核由 Windows 管理，`kernel.sh` 会跳过发行版内核包锁定；Docker 发布端口和主机 443/本机 LAN IP 受 Windows/WSL 网络模式影响，验证时按实际链路调整，不能据此判断生产网络 |
| 控制端 | Linux，Bash 4.4+（脚本使用 mapfile、间接展开和 `set -u` 下的空数组展开；低于 4.4 会在入口直接拒绝，macOS Bash 3.2 同样拒绝）、Python 3、jq、flock、OpenSSH 客户端、tar、gzip、curl、OpenSSL、sha256sum 等可用；正式安装使用 root |
| Web | HTTP 服务以普通用户运行；Linux、Python 3.8+、Bash 4.4+（与控制端脚本要求一致）、jq 和同机浏览器；只监听 127.0.0.1，不依赖 npm/CDN。页面部署另需 root 执行器、管理员保护的发布目录与独立数据/工作目录。表单密码只在页面内存；任务日志不脱敏 |
| 节点系统 | 配置可选 Ubuntu 22.04、Ubuntu 24.04、Kylin V10 SP3 2403 对应依赖类型；实际 OS、架构与 ISO/软件包须匹配 |
| 架构和版本 | 包内含 amd64/arm64 KubeKey（随包 v4.0.10，摘要表保留 v4.0.9 以便回退）；Kubernetes 只选制品包含的版本，可运行 `bash deploy.sh --versions` 查看；不能仅修改版本文本引入其它版本或切换 KubeKey 二进制 |
| 节点初始工具 | 已有 Python 3、OpenSSH/SSH 服务、Bash、systemd、ip、lsblk、findmnt、blkid、wipefs 等；分区/格式化另需 parted、partprobe、udevadm、mkfs.ext4 |
| SSH | 节点地址、名称、机器身份和主机公钥已核对；已有可用密钥或密码登录方式，密码模式需要控制端 sshpass；普通远端账号须支持授权范围内的 `sudo -n` |
| 单机 local | 正式 CLI 在目标机器本机运行，节点 IP 确属本机；最多一个 local 节点。浏览器所在电脑不决定 local 的目标 |
| 台账 | Python 3.7+ 标准库；须有权读取相关配置和回执，并能写新输出目录 |
| 完整离线预检 | 已有 7z 和相应 APT 检测能力；缺工具或权限将标为未核实，不会自动联网补齐 |

控制端 Ubuntu 24.04 amd64 缺少包内可提供的工具时，在确认包安装影响后选择一种 bootstrap 操作：

```bash
sudo bash deploy.sh bootstrap
# 只有需要密码 SSH 时才改用：
# sudo bash deploy.sh bootstrap --with-sshpass
```

bootstrap 会改变控制端软件包状态，不属于收包校验；它不包含完整操作系统或 Python。access 在 deps 之前执行，因此不能指望 deps 补齐最初接入和密钥检查所需的 Python/OpenSSH。

## 离线制品与空间

- `ARTIFACT_FILE` 指向解包后的内层 `artifact/kubekey-artifact.tgz`，保留相邻 tools、manifests.yaml 与 SHA256SUMS；不要填外层交付包。
- 按内层清单核对归档摘要，再填写 `ARTIFACT_SHA256`。Web 的固定路径按钮不读取归档内容、不计算摘要；CLI 向导会计算所选文件摘要。
- `deps.sh` 会安装静态 `busybox`（Ubuntu 为 `busybox-static`），集群验收脚本用它执行 DNS/HTTP 探测；缺少时 selected-node 验收会在 preflight 明确失败。
- 正常离线安装使用 `DEPS_MODE=iso`。`preinstalled` 只适用于已逐项核实依赖的环境；Web 的这个默认值不是预装证明。完整流程不支持 online 回退。
- 制品依赖基础 OS 已有 tar/Python 等软件，未证明严格断网全新 OS 的完整依赖闭包。前置检查中的 APT 模拟成功不等于实际包维护脚本和服务安装成功。
- 控制端应容纳外层归档、解包目录、内层制品缓存、工作目录和日志；节点按实际镜像与业务容量规划。native 默认要求根盘至少 20 GiB 可用，这不是整套部署容量保证。

第三方组件来源、版本和许可入口见 [第三方说明](third-party.md)。

`package.sh` 是联网重制内层制品的工具，不是离线安装步骤。不要在接收环境为消除缺项而无计划地重制介质或更换二进制。

## 数据与资源

确认目标是否已有 K8s、Docker/containerd 数据、停止的容器、卷、bind 挂载、PKI 或部署记录；任何一项存在都应先按 [维护手册](operations.md) 判断。不要因为进程停止、权限不足或客户端未安装就推断数据为空。

native 使用已有目录；existing 要求独立挂载、fstab 和实际设备已核验；新建格式化会破坏指定磁盘，必须另行确认。容器数据盘使用 Linux 文件系统：ext4 或已实测 ftype=1 的 XFS；exFAT/NTFS 不适用。不根据预检报告的“可回收”数字自动删除数据。

CPU/内存由现场按拓扑和业务规划。单宿主 VM 场景，宿主 MemAvailable 始终至少保留 4 GiB；这不是每个节点的最低内存承诺。长安装前建立宿主及所有节点的持续 I/O、内存和可观测性监督。新 I/O 错误、内存不足或监控失联时停止后续安装，保留进度、具体报错与停止锁，恢复可观测性并核验现场后再续跑。工具内部监控不覆盖所有节点，接收方需准备自己的全节点监督方案。

## 网络、时间与仓库

节点地址、Pod/Service CIDR、API 入口和现场路由不得冲突；确认 SSH、API、Harbor、DNS、NTP、CNI 所需网络通路。API/Harbor 域名及证书 SAN/CA 匹配，代理绕过集群、服务网段与仓库。该说明不是完整防火墙端口矩阵，须结合所选网络插件和现场方案制定。

单控制平面可用 ENDPOINT_TYPE=local；三控制平面要求 kube-vip 或已有 external LB，外部 LB 不由本工具搭建。三控制平面、HA Harbor 和故障切换不属于当前已完成实机验收的范围。

使用可信 NTP 来源。NTP_MODE=node 且没有上游时必须明确接受 NTP_ALLOW_LOCAL=true；它只提供内部基准，不证明 UTC 准确。NFS 默认 none，new 模式需要匹配的离线服务端依赖；挂载读写探测不代替业务 UID/GID 或 NFS PVC 验收。

包含 K8s 功能验收时使用 HTTPS Harbor。外部 Harbor 预先具备公开项目、对应平台镜像和可信公开 CA，配置使用 COMPONENTS=k8s，不将外部仓库主机加入 NODES；本流程不安装外部仓库、不建项目、不导入镜像。受管 Harbor 与外部仓库细节见 [多节点部署说明](multinode-deployment.md)。

独立 SSH_KNOWN_HOSTS 可固定 shell 接入的主机信任，应通过可信控制台取得公钥。随包 KubeKey v4.0.10 内部不校验 SSH 主机公钥，OpenSSH 前置检查不能消除它后续连接的窗口。要求端到端严格校验的环境须先解决该限制，不能将前置检查通过当成已满足要求。

## 完成后验收

完整流程会按组件范围运行服务、镜像、节点镜像和集群功能验收，并生成台账。另行执行验收前明确：`verify` 是基础健康检查；`cluster-verify` 会创建并删除本次临时 Pod/Service/PVC 等资源，不是纯只读操作。

功能验收的执行控制节点须已有 Python 3、kubectl、journalctl、findmnt、ip、OpenSSL、curl、相应运行库与 ldd，以及包含 httpd 的静态 BusyBox；诊断镜像 `openebs/linux-utils:4.3.0` 已通过仓库与 CRI 验收。缺失时停止，不联网下载补齐。

| 范围 | 能证明什么 | 仍需另行确认 |
| --- | --- | --- |
| Web 配置模式/config-check/plan | 配置语法、组合规则与静态拟议阶段 | 实际节点接入、存储、依赖、回执、健康与部署权限 |
| 服务/仓库与节点镜像验收 | 时间/所选 NFS 基础检查、所需镜像与平台摘要、各节点 CRI 拉取摘要 | 业务应用启动、冷缓存完整下载、NFS PVC、容量和性能 |
| selected-node | 首控制节点 DNS/TLS/Service 与可选本地 PVC 重建 | 其它节点网络/存储、重启恢复、HA |
| cross-node | 同架构声明 K8s 节点的 DNS/TLS 和每个有向异节点对的三条通信路径 | PVC 仍只在首控制节点验收；不等于所有节点存储、故障切换通过 |
| ledger/status | 已记录范围与证据状态 | 当前实时健康；无权限时状态未知，不是空环境 |

已有实机覆盖为 Ubuntu 24.04 amd64、单控制平面加两个 worker、外部 HTTPS Harbor，含 CRI 摘要、跨节点 DNS/TLS/Service 和首控制节点同节点 PVC 重建。这是特定环境的既有证据，不能代替接收方环境或本次修订重新部署验收。新修订的配置、接入保护与 Web 执行使用隔离配置和假后端回归验证；没有新增本版 Web 真实节点部署验收，不能把既有 CLI 实机证据直接当作 Web 实机通过；真实密码/主机信任、其它系统组合、HA、实机扩容/reset/redeploy、重启恢复、容量配额和严格断网新 OS 仍需独立验收。测试日志和现场记录由交付方单独保管，不随用户包分发。
