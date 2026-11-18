# 交互式一键部署指南

正常首装使用 `bash deploy.sh`，通过菜单和问答完成配置、确认与完整部署。内部仍按阶段执行和记录；用户无需逐条启动各阶段。分步操作是高级功能，见 [分步执行参考](staged-install.md)。多节点与单节点使用同一入口。

本指南适用 **20261114-r5**，KubeKey 二进制为 v4.0.10。本机 Web 保留配置工作台，并可显式连接管理员执行器，在页面确认后调用相同的完整首装流程，见 [Web 部署指南](web-deployment.md)。默认值、local/ssh 和三种 SSH 认证的选择见 [快速上手](quick-start.md)；文件路径和读取身份见 [配置衔接说明](configuration-workflow.md)。

## 1. 启动前准备

先按 [README](../README.md) 校验收到的本版发行包，在新目录解压。实际部署目录和配置路径使用无空格、中文或 `..` 的绝对路径。完整前置核对见 [部署前置条件](deployment-checklist.md)。安装控制端需要 Linux、root 权限、Bash、Python 3、jq、flock、OpenSSH 等；SSH 节点需预先具备 Python 3、OpenSSH 并可达，普通 SSH 用户支持 `sudo -n`。离线制品、对应 OS 的 ISO/依赖、磁盘空间、时间同步、DNS、网段及仓库方案必须按现场核对，不能用示例值代替。

`ARTIFACT_FILE` 指向包内的 **内层** `artifact/kubekey-artifact.tgz`，不是最外层交付包。保留相邻 `artifact/tools`、`manifests.yaml` 和校验清单。向导默认生成 `DEPS_MODE=iso`；已经预装依赖的环境需在部署前按模板配置 `preinstalled`。完整交付流程不接受 `online` 模式，也不会自动联网补齐缺项。

已有集群、运行时数据、初始化或部署记录时，先保留原配置、源码、state/runs、PKI 和数据，再判断是否属于维护；不能因进程已停止就当成新环境。已 reset 的集群不能用 `all` 复用旧阶段记录，须另行审查 `redeploy` 的配置、版本与影响。

当前交付不包含 HA Harbor 的实机验收承诺。采用 VM 实验环境时，长安装应有宿主和全部 VM 的持续 I/O/可观测性监督，宿主 MemAvailable 至少保留 4 GiB；工具内置监测并不覆盖所有节点。

## 2. 推荐路径：从菜单完成部署

在已解压项目目录运行：

```bash
sudo bash deploy.sh
```

按以下顺序操作：

1. 菜单显示本地记录，选择“安装”。回车默认退出，不会自动安装。
2. 选择安装范围：已有配置范围、整套安装、仅 Harbor，或复用仓库安装 K8s。首次默认范围为整套。
3. 没有配置时进入新建向导；已有配置时选择复用、按项修改或重新填写。默认配置文件是项目目录的 `cluster-vars.env`；在项目目录用 `CONFIG="$PWD/cluster-vars.env"` 记录其路径。sudo 向导创建的私有文件后续由管理员读取。
4. 核对执行前摘要中的节点、版本、组件范围、API/仓库地址、网段、数据策略和离线包；明确选择执行。确认处回车默认取消。
5. 按提示隐藏输入 Harbor/SSH 凭据。数据策略需要选盘或格式化时仍有独立核对和确认；“一键”不跳过这些操作边界。
6. 程序自动执行准备、依赖、基础服务、所选组件安装、镜像/集群验收和台账。阶段失败立即退出并保留运行记录，不会把后续阶段标为成功。

完整流程随组件范围变化：整套部署含 Harbor 与 K8s；仅 Harbor 不执行 K8s 验收；复用仓库安装 K8s 会先核验仓库内容，不隐式安装 Harbor 或导入镜像。包含 K8s 的完整流程要求 HTTPS Harbor。

## 3. 向导填写与修改

当前向导是终端问答，新建时先填写集群名称，支持节点清单新增、修改、删除；填写连接方式、架构/OS、角色、数据策略、API 入口、NFS、SSH、NTP、版本/域名和离线归档。bootstrap/key 方式可填写执行控制端的 SSH 私钥路径；此时只保存路径，实际接入阶段才检查密钥及授权冲突。识别节点平台时可能经已有密钥进行只读 SSH 查询；默认 SSH 信任模式可能记录首次公钥。配置向导不是“完全不连接节点”的操作。

已有配置有三种选择：

| 选择 | 用途与行为 |
| --- | --- |
| 复用 | 保持原配置内容，继续核对摘要；仍须通过配置和回执检查 |
| 按项修改 | 仅修改选中的常用字段，保留未选择字段和注释；在临时副本中整体校验，保存前备份，取消不覆盖原文件 |
| 重新填写 | 重新录入并生成配置；校验成功后备份原文件，再保存新配置 |

只想修改部署前草稿时，进入“配置与高级操作 → 修改已有配置”。已有工作流或部署/维护记录的配置受保护，不能通过普通修改或重新填写来改变实际集群；复用用于原配置的后续判断，恢复和维护仍选择对应操作。直接用文本编辑器修改也不会绕过指纹保护。

按项修改菜单提供 **7. 集群名称** 与 **8. SSH 认证与密钥路径**，仅适用于未绑定部署的草稿。默认集群名为 rise，留空 STATE_DIR 时默认目录随名称变化；修改名称不移动旧 state，也不证明现场没有同名集群。密钥路径只在 bootstrap/key 模式填写，password 模式不读取或分发密钥。已有工作流/回执保护仍生效，不能用改名或换密钥绕过。

向导不覆盖模板里的所有高级字段。`WORK_DIR`、显式 `STATE_DIR`、独立 known_hosts、跨节点验收模式、复杂证书/外部 Harbor 等应在部署前按 [配置模板](../cluster-vars.env.example) 核对和填写。特别是新建向导面向受管 Harbor，会要求仓库角色；外部 Harbor 从 [外部仓库样例](../examples/external-harbor.env) 准备可信 env 后选择“复用”，不要用重新填写把它改回受管仓库。

只生成配置并查看渲染结果、不开始安装：

```bash
bash deploy.sh render --wizard --env /path/to/cluster-vars.env
```

配置父目录需事先存在且可写。该命令会写配置和本地预览目录；向导可能只读识别节点。`render` 不安装组件，但预览及现场配置仍应按受控运维文件保管。纯静态检查使用下一节的 `config-check` 或 `plan`。

## 4. 加载已有 env

“env 导入”指通过 `--env` 加载已有可信配置文件，不是上传文件、复制到默认位置或执行任意来源的脚本。文件仍由 Bash source；加载前必须核对来源和内容，不接收未审查的命令替换、外部脚本等可执行语句。普通编辑只支持模板风格的独立字面量赋值，复杂手写 Shell 可能被拒绝自动修改。

首次手工填写在受控父目录中创建新文件，目标须不存在；父目录需事先准备且当前用户可写：

```bash
set -e
CONFIG=/srv/rise-config/site-new.env
test ! -e "$CONFIG"
test ! -L "$CONFIG"
(umask 077; set -C; cat cluster-vars.env.example > "$CONFIG")
```

Web 导出的 env 也可以作为已审查文件加载；保存草稿不会修改默认配置，导出后必须按实际文件位置赋值 CONFIG。模板有示例地址和占位值，必须填写后再使用。密码不写入 env；节点清单中的 `password_env` 填变量名，不填密码值。私钥和凭据也不放入公共交付文件。

加载指定文件并保留交互菜单：

```bash
CONFIG=/srv/rise-config/site-new.env
sudo bash deploy.sh --env "$CONFIG"
```

选择“安装 → 使用已有配置范围 → 复用”，即可使用该文件执行完整流程。若明确需要跳过菜单、直接进入完整部署确认，可用：

```bash
CONFIG=/srv/rise-config/site-new.env
sudo bash deploy.sh all --env "$CONFIG"
```

此命令仍会展示摘要、要求确认并按需读取凭据。它不会自动打开配置编辑器；需要边填写边部署时使用菜单，或显式加 `--wizard`。`-y` / `--non-interactive` 属于自动化高级用法，会跳过普通交互且要求预先提供配置/凭据，禁止无人值守格式化，不作为正常接收方的首选入口。

## 5. 部署前核对与后续接口

先按 [配置到 CLI 的衔接](configuration-workflow.md) 明确 CONFIG：Web 导出/自定义文件使用实际保存路径，默认向导文件为 `$PWD/cluster-vars.env`。普通用户自有配置可直接检查；sudo 生成的 root 0600 文件由有权限的管理员检查，不放宽生产文件权限。

普通用户自有配置：

```bash
set -e
CONFIG=/srv/rise-config/site-new.env
test -f "$CONFIG"
test -r "$CONFIG"
bash deploy.sh config-check --env "$CONFIG" --json
bash deploy.sh plan --env "$CONFIG" --json
```

默认 sudo 向导生成的配置：

```bash
set -e
CONFIG="$PWD/cluster-vars.env"
sudo test -f "$CONFIG"
sudo test -r "$CONFIG"
sudo bash deploy.sh config-check --env "$CONFIG" --json
sudo bash deploy.sh plan --env "$CONFIG" --json
```

去掉 `--json` 可查看文本输出。这两个入口不部署、不连接节点，不建立阶段成功记录；静态通过不代表 SSH、磁盘、依赖和实际仓库已通过。`render` 用于查看实际配置模板；菜单“检查环境”会连接节点采集信息并写本地报告。

JSON 输出使用版本字段标识契约；调用方还应检查进程退出码。它是配置校验/计划读取接口，不是任务提交或部署授权，也没有把任意 Bash env 变成安全数据。本版 Web 先受限解析再生成安全字面量 env，调用同一最终校验；不能把上传原文直接交给 root source。

SSH 免密计划只指控制端到各节点，不建立节点两两免密，不分发私钥。正式 access 才检查已有私钥/公钥及远端授权冲突；不自动覆盖未知密钥或绕过 authorized_keys 限制。普通远端用户仍需 sudo -n，Web 的配置模式、config-check 和 plan 不证明这些实际条件满足；Web 提交的部署任务在正式 access 阶段执行相同检查。密钥失败保留原文件与 access 记录，处理范围详见 [快速上手](quick-start.md)。

## 6. 完成、失败与高级操作

使用菜单“查看状态”，或：

```bash
bash deploy.sh status
```

自定义状态目录时使用 `status --state-dir /absolute/path/state-base`。原记录由 root 保管时，由获授权管理员以 sudo 运行同一只读命令。无权遍历目录或读取记录时明确显示状态未知/读取失败并返回非零，不代表没有旧集群。状态是本地历史记录，不等于实时健康；已删除集群可能仍保留历史成功阶段。完整流程会重验基础服务、镜像、集群功能并生成台账；接收方应核对实际阶段记录、范围和异常，不只看一句完成提示。

失败后保留配置、回执、运行目录、节点日志和停止锁，先解决报错并恢复可观测性。需要更多诊断信息时，在受控终端用 `--debug` 重跑同一阶段（日志不脱敏，可能含凭据）。只有匹配的未完成部署才选择“维护与恢复 → 继续上次部署”；存储初始化曾中断时不能自动重做 prepare。已完成集群不应为验证新代码而重跑首装，已 reset 的集群也不应直接 resume。

| 入口 | 使用场景 |
| --- | --- |
| 菜单“安装” / `all` | 新环境从接入到验收、台账的完整流程 |
| `install` | 准备、依赖和服务初始化均已有成功记录后，组合安装/验收；不自动补齐这些前置阶段 |
| `resume` | 核验原配置、代码、身份与证据后恢复未完成流程；不是忽略错误重跑 |
| 菜单“分步部署” / 各阶段命令 | 高级诊断、阶段验证和经过审查的运维操作 |
| `verify` | 已安装组件的实时基础健康检查 |
| `reset` / `redeploy` / `add-workers` | 独立维护流程，按原回执和操作范围审查，不属于首装快捷方式 |

分步功能和前置依赖详见 [高级分步执行参考](staged-install.md)；多节点、SSH、存储验收与全节点监控限制见 [多节点部署说明](multinode-deployment.md)。`package.sh` 是联网重制内层离线制品工具，不是部署入口或“一键安装”的前置命令。

实际维护按 [维护与故障处理手册](operations.md) 先备份、预览并核对 reset 的影响：它会清空 IPv4 filter/nat 表规则和 IPVS 服务，并可能重启容器运行时及 Harbor。工作区 PKI 保留不代表节点证书目录保留；`/etc/kubernetes` 与 `/etc/ssl/etcd` 会被删除，应先独立备份节点配置、PKI 和 etcd 快照。保留目录不等于已完成备份；共享宿主上的非 K8s 网络影响须单独审查。
