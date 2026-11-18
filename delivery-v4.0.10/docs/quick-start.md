# 默认值、连接方式与快速上手

本说明适用 20261114-r5。默认值用于减少重复填写，不能代替现场确认。先把交付包解压到新目录，路径使用 ASCII 字母、数字、`/._-`，不要包含中文、空格或 `..`。例如 `/opt/rise/delivery-v4.0.10`。先核对外层包及包内校验清单，再启动入口。

## 选择入口

配置草稿和静态预览，以普通用户运行：

```bash
bash deploy.sh web --data-dir /tmp/rise-config-drafts --port 8765
```

浏览器打开当前终端输出的临时本机链接。草稿目录应在项目外，服务只监听 127.0.0.1；不使用 sudo。默认配置模式不连接节点或执行部署。Harbor 与 SSH 密码可直接填在表单“凭据”区（仅页面内存），安装确认展示将执行的阶段与配置变更，勾选同意即可；日志不脱敏，默认 Info，可切换 Debug。需要页面一键部署时，按 [Web 部署指南](web-deployment.md) 显式连接管理员执行器；执行器在提交确认后调用正式 CLI，包括实际接入检查和已选择的免密准备。按 Ctrl+C 停止，保存的草稿仍保留；`/tmp` 不保证长期保存。

当接收方已经具备离线前置条件并明确准备开始新环境安装时，以正式 CLI 菜单为主入口：

```bash
sudo bash deploy.sh
```

选择安装范围后新建或复用配置。向导可填写集群名、节点、存储、SSH 认证/密钥路径、网络、版本和制品；执行前仍有摘要与确认。分步命令用于高级操作。原有集群须走维护流程，不为体验表单或验收而重跑首装。

## 配置保存后怎样交给 CLI

Web 保存的是项目外草稿；点击“导出 env”后，将下载文件保存在受控位置，审阅后再显式加载。CLI 向导默认写项目根目录 `cluster-vars.env`，传入 `--env` 则写所指定的文件。

按实际来源选择并明确路径，不能直接使用未定义的 CONFIG：

```bash
# Web 导出或自定义 --env：替换为实际保存位置。
CONFIG=/srv/rise-config/site-new.env
# 如使用默认 CLI 向导文件，则改用项目目录中的路径：
# CONFIG="$PWD/cluster-vars.env"
```

普通用户保管的文件由该用户运行 config-check/plan；sudo 向导创建的 root 0600 文件由获授权管理员读取。不要放宽已有配置或 state/runs 的权限，也不要用 sudo 启动 Web。三种来源的完整命令、读取检查和加载方式见 [配置到 CLI 的衔接](configuration-workflow.md)。

## 常用默认值

| 字段 | 初始值或推荐行为 | 如何选择 |
| --- | --- | --- |
| CLUSTER_NAME | rise | 部署前改为本环境唯一名称；小写字母起始，后接小写字母、数字或短横线。默认状态目录为项目的 state/集群名。Web 草稿名称是另一个概念 |
| COMPONENTS | all | all 安装仓库与集群；harbor 仅仓库；k8s 复用仓库安装集群。外部 Harbor 仅允许 k8s |
| KUBE_VERSION | 从 configs/v*.yaml 自动发现（当前最高 v1.36.4） | 只能选择离线制品包含的版本；只改文本不产生新版本镜像 |
| KK_VERSION | v4.0.10 | 随包二进制；回退到 v4.0.9 须先用 `./tools/kk-fetch.sh` 重装并核对摘要，不能只改字段 |
| ARTIFACT_FILE | 不固定绝对路径 | CLI 推荐当前包内归档；Web 点击“填入包内离线归档路径”采用当前解包目录的 artifact/kubekey-artifact.tgz。不是外层交付包，也不是浏览器上传 |
| ARTIFACT_SHA256 | 空，须核对 | 快捷填入会清空旧摘要，防止新路径沿用旧值。先核对 artifact/SHA256SUMS，再填写内层 tgz 摘要；CLI 向导会计算所选文件摘要 |
| PKI_ROOT_CERT / PKI_ROOT_KEY | 空，由 KubeKey 生成根 CA | 仅需自带根 CA 时同时填写控制端路径；私钥须 0400/0600，安装前校验并复制到 WORK_DIR/pki，不能中途更换。HARBOR_CERT/HARBOR_KEY 仍不参与签发 |
| DEPS_MODE | Web 模型 preinstalled；CLI 新建向导 iso | Web 快捷填入同时选 iso。iso 使用已准备的匹配离线 OS 介质/包；preinstalled 必须实际预装并通过检查。online 不适用于完整离线交付流程 |
| 节点 IP | 192.0.2.10 等文档示例地址 | 必须替换为实际地址；Web 不探测本机、节点 OS 或拓扑 |
| connection | Web 示例 ssh；CLI 可选 local/ssh | local 是执行控制端本机，最多一个；ssh 是远端节点。它与 API 入口 ENDPOINT_TYPE=local 无关 |
| SSH 用户 / 端口 | root / 22 | 可用普通用户，但实际 CLI 需要远端 sudo -n；没有单独填写 sudo 密码的流程 |
| 数据策略 | Web 示例 native；CLI 向导提供选择 | native 使用已有目录，不等于格式化；existing 要求已有独立挂载；auto 在正式初始化时交互选择；format 会破坏指定整盘且须另外确认 |
| INSTALL_NERDCTL | true | 默认在前置阶段为全部 K8s 节点安装随包 `nerdctl`（`v2.2.1`）并配置 `/etc/nerdctl/nerdctl.toml`（`namespace="k8s.io"`、`cgroup_manager="cgroupfs"`） |
| ENDPOINT_TYPE | Web 默认 kube-vip；CLI 单机默认 local | 单控制平面可用 local；多控制平面（`3 / 5 / 7...` 正奇数 Master+Etcd 同机）须选择 `kube-vip`（控制平面漂移 VIP）、`haproxy`（纯 Worker 内置本地 HAProxy 代理，免 VIP）或 `external`（已有外部 LB） |
| Pod / Service CIDR | 10.233.64.0/18 / 10.233.0.0/18 | 须互不重叠，不能与节点、外部入口和实际网络冲突 |
| LOCAL_STORAGE / LOCAL_PATH | true / /data/local-pv | 节点本地 PV，节点故障不自动迁移数据 |
| NFS_MODE / NTP_MODE | none / existing | NFS 默认不安装；时间默认保留并验收现场 chrony。其他模式需要相应服务端、离线依赖及配置 |

Web 对各枚举值显示中文含义和选项说明，保留原始 env 值方便对照。固定包内文件不存在、为链接或解包路径不符合配置路径规则时，不伪造推荐路径，也不扫描其他目录。快捷填入仅修改当前表单；已有草稿不会在页面加载时被自动覆盖。

## 日志与调试

- 日志级别由 `RISE_LOG_LEVEL` 控制：`quiet` / `info`（默认）/ `debug`。`--debug`（或 `--log-level debug`）会输出 DEBUG 行、`set -x` 命令追踪与失败位置。
- Web 执行器会对当次提交的内存密码实施精确 `[REDACTED]` 掩码，并在日志超过 `4 MiB` 时保留头部 `1 MiB` 与最新尾部 `3 MiB`；CLI 原始日志仍可能包含私钥路径和完整命令，须按凭据材料保管，不要粘贴到公共工单或外发。
- Web 任务默认按 Info 显示，任务详情可切换 Debug；提交前可勾选“以调试模式运行”。

## 单机与 SSH 登录

| 使用方式 | 节点 connection | SSH_AUTH_MODE | 行为 |
| --- | --- | --- | --- |
| 单机本地安装 | local | 不用于这个节点 | CLI 在目标机器本机运行。节点 IP 须实际属于控制端；Web 上的选择不会把另一台电脑变成本机 |
| 已配置控制端免密 | ssh | key | 使用 SSH_KEY 指定的现有私钥，不创建私钥、不分发公钥；缺少 .pub 时可安全派生公钥，不可用时停止 |
| 配置控制端到节点免密 | ssh | bootstrap | 检查/准备专用控制端密钥，先尝试密钥接入，必要时在 CLI 隐藏输入密码；所有节点接入及身份核对后再分发公钥并验证 |
| 保持密码登录 | ssh | password | 每个 SSH 节点第 13 列填写密码变量名（如 NODE1_PASSWORD）；CLI 读取实际密码，不配置免密 |

这三种认证策略是同一 SSH_AUTH_MODE 的互斥选项，避免再加含义冲突的“免密”开关。SSH 密码认证需要 sshpass。SSH 免密与 sudo 免密是两项独立条件；非 root 远端用户仍须事先具备明确授权的免密 sudo。

bootstrap 只配置“控制端 → 各节点”，不建立节点之间两两互信，不复制控制端私钥到各节点。配置表单、config-check 和 plan 仅表达这项计划，不证明连接已打通。Web 部署任务与 CLI 均在正式 access 阶段执行密钥检查和所选的免密准备；Web 执行器只接受管理员控制的密钥路径。

## 密钥存在性与冲突

正式 CLI 的 access 阶段再检查执行控制端 SSH_KEY 的类型、所有者/权限及私钥有效性，核对已有公钥是否与私钥匹配。拒绝异常链接、孤立公钥、不匹配的密钥对或不支持的密钥；保留原文件，不自动覆盖或修复未知密钥。key 模式只复用现有密钥；bootstrap 在安全路径中缺少密钥时才创建，已有可用私钥缺少公钥时可派生公钥。

当前支持未加密的 ed25519、RSA、ECDSA 专用部署私钥；不支持加密私钥、硬件安全密钥或证书密钥。私钥须为执行 CLI 用户所有的单链接普通文件，权限为 0400 或 0600；所在目录须为该用户所有且不可被组/其他用户写入。以 root 部署时不能直接复用另一用户所有的私钥，须另行准备符合策略的专用密钥，不自动改所有权、权限或移除口令。控制端及 SSH 节点须在 access 阶段前已有 Python 3 与 OpenSSH；不能依赖之后的 deps 来补齐密钥检查工具。

仅 bootstrap 的分发路径检查远端 authorized_keys 并保留已有内容；key 模式只验证接入、不追加授权。对 bootstrap，同一密钥的不同注释不应重复添加；同一密钥存在 from=、command=、restrict 等限制时，拒绝追加一条无限制公钥来绕过它。异常路径/文件或不能安全解释的冲突应停止，由管理员通过可信渠道核对，不自动删旧条目。局部失败可能已在先处理的节点安装公钥，必须保留 access 日志，不能假定全局回滚。

全部目标的身份与授权文件预检通过后才开始分发；写入时再次核对以防期间变化。既有 HOME、.ssh 和 authorized_keys 不自动 chmod；不可安全创建/追加时停止。正式统一入口和初始化接入复用相同策略；正常首装仍优先使用 deploy.sh 菜单，不直接绕过阶段前置。

客户端私钥匹配检查与服务器主机公钥信任是两件事。可用独立 SSH_KNOWN_HOSTS 固定已从可信控制台核对的主机公钥；遇主机公钥变化不自动删除记录。默认 accept-new 不等于已有可信固定，且随包 KubeKey v4.0.10 内部仍缺少主机公钥校验，前置 OpenSSH 检查不能消除后续窗口。

已部署后不得通过修改集群名、SSH 配置、state 目录或删除回执绕过原配置指纹。详细边界见 [部署指南](deploy-guide.md)、[Web 指南](web-config.md) 和 [维护手册](operations.md)。
