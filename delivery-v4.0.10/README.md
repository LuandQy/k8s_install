# KubeKey v4.0.10 离线部署交付 — 工程化收敛版（20261115）

本交付支持 **CLI（`./deploy.sh cli`）和本机 Web（`./deploy.sh web`）双入口**，共用 `lib/workflow.sh`、`lib/cluster-state.sh`、同一份阶段状态和 `lib/ledger.py`：选择范围，填写或加载配置，确认后自动完成安装、验收和台账。CLI 的 `--step <阶段>` 可在 Web 任务中途/结束后由管理员接管或重试。KubeKey 版本升级、K8s 版本/Artifact 扩展、OS/bootstrap 扩展的 SOP 见 [维护与故障处理手册](docs/operations.md)。随包 KubeKey 二进制为 **v4.0.10**，只存放在 `tools/{amd64,arm64}/kk`。

先区分环境：没有既有集群、容器运行时数据和部署回执的新环境按首装流程操作；已有集群或数据的环境按维护流程操作。容器停止、状态记录不可读或界面没有显示记录，都不能作为空环境证明。

## 1. 接收与校验

保持外层交付目录完整，先阅读接收说明和文件清单。将包解压到新的可写目录，路径使用 ASCII 字母、数字、`/._-`，例如 `/opt/rise/delivery-v4.0.10`；不要覆盖原部署目录。外层归档名为 `delivery-v4.0.10-20261115-r6.tar.gz`。

在外层交付目录验证归档后解包：

```bash
set -e
sha256sum -c SHA256SUMS
sha256sum -c delivery-v4.0.10-20261115-r6.tar.gz.sha256
unpack_dir=$(mktemp -d "$PWD/unpack-20261115-r6.XXXXXX")
tar --no-same-owner -xzf delivery-v4.0.10-20261115-r6.tar.gz -C "$unpack_dir"
cd "$unpack_dir/delivery-v4.0.10"
sha256sum -c SHA256SUMS
sha256sum -c SOURCE_SHA256SUMS
(cd artifact && sha256sum -c SHA256SUMS)
for checksum in bootstrap/*.sha256; do (cd bootstrap && sha256sum -c "$(basename "$checksum")"); done
```

任一步失败即停止。摘要应另经可信交付渠道核对；随未知来源归档一起取得的摘要不能独立证明来源。包内根清单覆盖自身以外的全部交付普通文件（含 `tests/` 回归代码）；源码清单覆盖源码、模板、样例和手册。测试记录、内部审计、历史材料、草稿、现场配置和凭据不属于本交付包内容。

> 本副本是开发副本：在 20261114-r5 基础上包含 Web 交互改造、日志分级、CLI 加固、KubeKey v4.0.10 模板合并与二进制切换（离线制品不重制）。`tests/` 仅用于本地回归，不属于交付内容；重新发布前须重新生成摘要与外层归档。

## 2. 核对前置条件

先按 [部署前置条件与验收边界](docs/deployment-checklist.md) 核对控制端/节点依赖、离线制品、磁盘、网络、时间、仓库及监控。示例地址、默认值和静态计划不证明现场已就绪。

## 3. 准备配置

需要本机表单时，以普通用户启动：

```bash
bash deploy.sh web --data-dir /tmp/rise-config-drafts --port 8765
```

在同一台电脑打开终端给出的临时链接。这条命令默认提供配置模式：三步向导支持填写/保存、只读校验与计划、执行器就绪后直接提交后台安装；第 1 步提供紧凑三列参数、节点矩阵、数据盘派生预览与 env 预览，第 3 步支持 prepare/Harbor/K8s 分阶段独立提交。Harbor 管理员密码内嵌在勾选 Harbor 角色的节点矩阵行，所有 Harbor 行共享同一个页面值；节点 SSH 密码在节点矩阵行内，并和认证方式联动。页面不保存草稿，密码只保留在当前页面内存；配置持久化使用导入/导出 .env。第 3 步“一键开始安装”会校验表单并直接提交后台任务，不再弹二次确认。日志不做脱敏。需要直接从页面部署时，由管理员启动独立执行器，并添加 `--executor-socket` 连接，见 [Web 一键部署](docs/web-deployment.md)。按 Ctrl+C 停止；`/tmp` 不是长期配置备份，请使用导出 .env。

也可直接使用 CLI 向导；显式入口为 `sudo ./deploy.sh cli`。需要复用已审阅配置、不进入菜单时使用 `sudo ./deploy.sh cli --auto-default --env /absolute/site.env -y`；需要从阶段边界接管时使用 `sudo ./deploy.sh cli --step <stage> --env /absolute/site.env`。无论采用 Web、向导还是模板，都按 [配置到 CLI 的衔接](docs/configuration-workflow.md) 明确 **CONFIG 实际路径、配置所有者和检查身份**。归档 SHA256 不需要在 Web 表单手工填写：后端优先读取同目录 `.sha256`，否则读取 `artifact/SHA256SUMS`，部署时仍由 CLI 校验实际字节；CLI 也可执行 `./deploy.sh artifact-sha256 --file /absolute/archive.tgz`。Web 不会自动更新 `cluster-vars.env`；须导出并审阅后显式加载。sudo 向导创建的 0600 配置应由有权限的管理员检查，不放宽权限来迁就普通用户读取。

## 4. 新环境一键部署：CLI 或 Web

选择 CLI 时，完成前置核对后，在新解包目录运行：

```bash
sudo ./deploy.sh cli
```

选择“安装”，填写或复用配置，审阅摘要并确认。菜单回车默认退出，执行确认回车默认取消。要加载已经导出并审查的文件，使用 `sudo bash deploy.sh --env /absolute/path/site.env`；它保留交互菜单，不复制配置到默认位置。

选择 Web 时，按 [Web 一键部署](docs/web-deployment.md) 安装受管理员保护的独立发布副本，启动执行器与普通用户网页服务；三步向导第 3 步会直接校验并提交后台安装，不弹二次确认，页面展示日志和台账。Web 仅支持新环境首装；维护及需要交互格式化的场景使用 CLI。

CLI 完整操作见 [交互式一键部署指南](docs/deploy-guide.md)。默认值、local/SSH 密钥/密码和控制端到各节点免密的含义见 [快速上手](docs/quick-start.md)。外部 Harbor 和跨节点验收见 [多节点部署说明](docs/multinode-deployment.md)。默认拓扑是 3 控制平面 HA + 单 Harbor + NTP/NFS 自建；Harbor HA 使用 `examples/harbor-replica.env`。Web 任务详情可下载最近一次 `environment-ledger.xlsx`，CLI 使用 `./deploy.sh ledger --env ...`，两者格式一致。

## 5. 验收与已有集群维护

完整流程结束后核对阶段结果、功能验收与台账；本地状态记录不等于实时健康。`status` 无权读取记录时显示状态未知并返回非零，不能据此判断可重新首装。

已有集群、失败恢复、备份、reset、redeploy 和扩容按 [维护与故障处理手册](docs/operations.md) 操作。保留与原回执匹配的代码、配置、state/runs、PKI 和数据；新包不能覆盖运行目录后直接续跑，也不能修改指纹或删除回执绕过保护。

## 手册索引

| 手册 | 适用任务 |
| --- | --- |
| [架构与执行链路](docs/architecture.md) | CLI/Web、交付脚本与 KubeKey 的职责边界、一次首装的阶段流、输入产物与失败处理 |
| [前置条件与验收边界](docs/deployment-checklist.md) | 首装前核对依赖、资源、网络、离线限制及验收范围 |
| [配置到 CLI 的衔接](docs/configuration-workflow.md) | Web/向导/模板的 CONFIG 路径、读取身份与只读检查 |
| [快速上手](docs/quick-start.md) | 默认值、参数解释、local/SSH 与免密冲突保护 |
| [交互式部署](docs/deploy-guide.md) | 菜单、向导、env 复用、修改及完整安装 |
| [Web 配置工作台](docs/web-config.md) | 表单、.env 导入/导出及只读计划 |
| [Web 一键部署](docs/web-deployment.md) | 管理员启用执行、任务确认、阶段日志和停止边界 |
| [多节点部署](docs/multinode-deployment.md) | 外部 Harbor、跨节点验收、SSH 信任与恢复 |
| [维护与故障处理](docs/operations.md) | 状态、备份、续跑、扩容、重建和清理影响 |
| [高级分步参考](docs/staged-install.md) | 阶段前置、命令与诊断证据 |
| [WSL 本地验证记录](docs/wsl-validation.md) | WSL 单节点实装结果、测试专属网络适配与未覆盖边界 |
| [第三方组件与许可入口](docs/third-party.md) | 随包组件来源、版本目录及许可文件位置 |
| [KubeKey v4.0.10 评估](docs/kubekey-4.0.10.md) | Harbor 部署与证书来源、v4.0.10 修复清单、已合入项与升级/回退 |
| [后续优化点](docs/optimization-backlog.md) | 已识别但未实施的事项与优先级 |

本交付提供已说明范围内的部署工具，不代表所有系统组合、HA、重启恢复或严格断网新 OS 依赖闭包均已实机验证。已知限制集中列在前置条件手册；接收方仍需完成自己的现场验收。
