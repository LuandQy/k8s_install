# 本机 Web 一键部署

本说明适用 **20261114-r5**。Web 和 `bash deploy.sh` 都可完成新环境安装；两者调用同一套配置、接入、安装和验收逻辑。Web 默认只有配置能力，管理员显式启动执行器并连接后，页面才开放“准备部署”。不需要 Node、npm 或联网加载页面资源。

本副本为三步极简向导：第 1 步直接编辑配置（可用 .env 导入/导出持久化），第 2 步校验与计划，第 3 步直接提交后台安装。Harbor 管理员密码内嵌在勾选 Harbor 角色的节点矩阵行，节点 SSH 密码也在矩阵行内；密码只保留在当前页面内存。第 3 步不再弹二次确认，任务日志不做脱敏。

## 选择入口

| 场景 | 入口 |
| --- | --- |
| 三步向导填写配置、.env 导入/导出、只读校验与计划、直接提交后台安装 | 普通用户运行 `bash deploy.sh web --data-dir ...` |
| 在控制端本机浏览器完成新环境一键部署 | 启动下文的 root 执行器与普通用户 Web 服务 |
| CLI 交互式首装、向导、env 复用 | `sudo bash deploy.sh` |
| 旧集群维护、失败恢复、扩容、重建、清理、需要交互格式化磁盘 | 使用原部署目录和 CLI，见 [维护手册](operations.md) |

Web 执行固定为 `deploy.sh all --env <执行器生成配置> --non-interactive`。表单的 COMPONENTS 决定整套、仅 Harbor 或仅 K8s 范围；流程包含适用的接入、基础准备、依赖、基础服务、仓库、镜像、K8s、功能验收和台账阶段。数据策略仅接受 native/existing；不提供任意命令、磁盘格式化、reset、redeploy、resume 或扩容接口。HA Harbor 在页面仅开放配置、校验和只读计划，提交执行会被拒绝；须完成 VIP、token 共享与 VRID 实机验收后由 CLI 执行。

## 管理员启用执行

以下步骤只适用于已批准部署的新环境，**不是收包校验时必须执行的操作**。先完成 [前置条件清单](deployment-checklist.md)，确认节点、数据和目标范围。启用执行器相当于授予指定本机用户使用本套部署工具管理所填目标节点的权限；它不是面向不可信用户的权限沙箱。

HTTP 服务仍以普通用户运行、固定监听 127.0.0.1；root 执行器不监听 TCP，通过 Unix socket 只接受管理员指定 UID 的连接。不得反向代理到外网、共享访问令牌或让多个用户共用此会话。

### 1. 安装独立且受保护的发布副本

按照 README 校验外层归档，选择全新 ASCII 路径，不覆盖原项目。以下示例从已校验的外层交付目录运行，假定 `/opt/rise/releases/20261114-r5` 尚不存在：

```bash
set -e
sha256sum -c SHA256SUMS
sudo install -d -o root -g root -m 0755 /opt/rise/releases
sudo mkdir -m 0755 /opt/rise/releases/20261114-r5
sudo tar --no-same-owner -xzf delivery-v4.0.10-20261114-r5.tar.gz \
  -C /opt/rise/releases/20261114-r5
cd /opt/rise/releases/20261114-r5/delivery-v4.0.10
sha256sum -c SHA256SUMS
sha256sum -c SOURCE_SHA256SUMS
(cd artifact && sha256sum -c SHA256SUMS)
(cd bootstrap && sha256sum -c bootstrap-noble-amd64.tar.gz.sha256)
```

发布目录、其祖先、源码和工具必须由 root 控制，禁止组和其他用户写入，不允许符号链接。执行器会拒绝普通用户可修改的工作区；不要通过递归修改旧项目或生产目录权限来绕过检查。需要安装控制端依赖时，按前置条件手册单独使用离线 bootstrap，核实 Python、Bash、jq、SSH 等依赖齐备后再启用执行器。

### 2. 启动 root 执行器

由获授权的普通用户在上述新项目目录执行，`id -u` 取该用户 UID。不要在 root shell 中用这个命令代替普通用户身份：

```bash
set -e
WEB_OPERATOR_UID=$(id -u)
test "$WEB_OPERATOR_UID" -ne 0
sudo bash deploy.sh web-executor \
  --project-root "$PWD" \
  --data-dir /var/lib/rise-web-executor \
  --work-root /data/rise-web \
  --socket /run/rise-web-executor/control.sock \
  --allowed-uid "$WEB_OPERATOR_UID"
```

保持该终端运行。数据、工作目录必须是独立的管理员专用目录（0700），首次使用须为新目录或空目录；再次启动只接受已有执行器专用标记匹配的目录。不能指向既有集群的 state、runs、PKI 或数据目录；执行器拒绝不安全路径和未知的非空目录，不会接管普通用户文件。

工作目录优先位于已经挂载的独立数据分区。示例 `/data/rise-web` 只是路径，创建 `/data` 目录不等于完成独立挂载；启动前核对它实际所在的文件系统和可用空间。若确认允许控制端使用根分区，应在表单中显式设置 `ALLOW_ROOT_WORKDIR=true`，并满足 `MIN_ROOT_FREE_GIB`（默认至少 20 GiB 根分区可用空间）。单个 local/native 节点沿用 CLI 的根分区许可规则，但仍检查空间。默认 `ALLOW_ROOT_WORKDIR=false`；仅选择 iso 制品或空间充足，不会自动允许 SSH 部署使用根分区工作目录。共享 CLI 会在相关阶段检查这些条件，静态准备摘要不代替现场核查。

运行后不要修改发布源码、工具或输入文件。发布源码或工具变更会使执行器拒绝新提交；外部密钥、证书和主机信任文件只检查受控路径等条件，并非全部内容都绑定到准备摘要。应保持这些输入不变，执行阶段继续由共享 CLI 按相应规则核验，不能把静态准备成功当作文件内容已获验证。

### 3. 普通用户启动网页

另开普通用户终端，进入**同一个 root 所有的发布副本**：

```bash
cd /opt/rise/releases/20261114-r5/delivery-v4.0.10
bash deploy.sh web \
  --data-dir /tmp/rise-config-drafts \
  --executor-socket /run/rise-web-executor/control.sock \
  --port 8765
```

在同一台控制端电脑的浏览器中打开终端输出的临时链接。页面显示执行器主机、身份和能力后才可准备部署。未配置 socket 时保持配置模式；socket 不存在、权限或 root 对端身份不符时显示错误，不能提交。启动 Web 不需要 sudo，也不向页面提供 sudo 密码。

`/tmp` 适合临时数据，长期使用时换成自己受控的项目外专用目录。.env 导入规则与 CONFIG 导出衔接见 [Web 配置指南](web-config.md)。

## 页面部署步骤

1. 页面默认载入高可用模板，填写真实节点与参数。选择执行器发布副本中的 `artifact/kubekey-artifact.tgz`；SHA256 由后端读取同目录 `.sha256` 或 `artifact/SHA256SUMS` 自动匹配，部署时 CLI 再校验实际字节。默认集群名和示例地址需要按现场修改。
2. 运行配置校验和只读计划，修正参数问题。只读成功不是部署许可，不证明节点、磁盘、网络或离线制品真实可用。
3. 点击准备部署。核对控制端、root 执行身份、所有节点、连接方式、数据策略、版本、制品、完整阶段和执行器生成的 STATE_DIR/WORK_DIR。实际目录由执行器管理，覆盖表单中的这两个路径，但不会改写表单。
4. 进入第 3 步：可点击“一键全量安装”（`deploy.sh all`），也可分别提交前置检查（`access→prepare→deps→services-init→services-verify`）、Harbor（`harbor-install→harbor-projects→images-import→images-verify`）或 K8s（`k8s-install→node-images-verify→cluster-verify→ledger`）。建议按 1→2→3 执行；前端自动校验表单、生成计划并提交后台任务，不显示二次确认。阶段徽章随任务状态更新，停止只在阶段边界生效。密码来自当前页面凭据；密码只存在于页面内存，不会进入配置对象、任务元数据或默认 env 导出。
5. 提交后保留任务 ID，查看实际阶段、任务日志（未脱敏）及最终结果。一次只运行一个任务，忙时拒绝新任务，不排队。关闭浏览器或断线不会终止任务，重新打开可刷新任务列表继续查看。
6. 完成后仍须核对 CLI 生成的节点与集群验收证据和台账；`succeeded` 表示所选流程以零退出码结束，不代替现场业务验收。失败时保留原配置与回执，由管理员通过 CLI 核查。

同一 request_id 的重复提交只查询原任务，不会重新执行；超时或网络错误可能发生在任务已经启动之后，必须查询原 ID，不能重新生成任务。执行器永久保留集群名占用记录，同名失败/停止任务也不能重新首装。新集群名不是绕过旧集群保护的方法；系统不能仅凭名称证明目标节点空闲。

## local、SSH 与凭据

- local 指执行器所在控制端本机，最多一个节点；不是“当前浏览器所在的任意电脑”。IP 必须匹配实际主机。
- key 使用 root 可读的管理员密钥（私钥仅 root 读取，父目录受保护）；bootstrap 自动生成默认部署密钥并分发；password 在节点矩阵行内填写节点密码。密码只保留在页面内存，刷新后需要重填。
- 实际密钥是否匹配、已有授权冲突、主机信任和 sudo 能力均由共享 CLI 的 access 阶段检查，不自动覆盖未知私钥或冲突授权，不分发私钥。普通远端用户仍须具备所需的 `sudo -n` 权限，SSH 密码不能代替 sudo 密码。
- Web 执行器只接受管理员控制的 SSH/known_hosts/CA/证书输入路径。准备新增 bootstrap 密钥时，其父路径也必须受 root 控制；已有公钥但私钥缺失会被拒绝，交由管理员先处理冲突。不要上传私钥正文。
- 仅 `COMPONENTS` 包含 Harbor（all/harbor）时收集 Harbor 密码；Harbor 关闭/仅 K8s 计划不要求该密码，但仍沿用 CLI 的仓库复用与只读边界。字符限制与 CLI 相同。
- 节点 password_env 由执行器改为受控名称；导入文件不能通过 PATH、BASH_ENV 等变量影响 root 子进程。

任务生成的 env 不保存密码（除非导出时显式包含），底层 CLI 会在 root 私有 inventory、回执和原始日志中保留认证资料。Web 执行器的 `JobLog` 会对本次任务提交的内存凭据做精确 `[REDACTED]` 掩码，并在日志超过 `4 MiB` 时保留头部 `1 MiB` 与最新尾部 `3 MiB`；由于日志中仍包含路径与命令上下文，执行器目录仍须按敏感材料保管，不能加入对外交付包或公开问题截图。

调试模式：提交前勾选“以调试模式运行”会给 CLI 传入 `--debug`，输出 DEBUG 行、`set -x` 命令追踪和失败位置。日志区默认只显示 Info/Warn/Error，可在任务详情切换 Debug 查看全部行；页面提示检测到错误时可据此排查。

## 停止、失败与关闭

“请求停止”只写执行器自己的停止标记。当前阶段继续运行，完成后停止进入下一阶段；不会立即取消安装、不会强制杀远端进程，也不会回滚数据。界面显示 stop_requested 时仍可能有操作进行，须等待最终状态并核对节点。长安装阶段可能需要较长时间。

停止普通用户 HTTP 服务不会停止执行器或任务。正常关闭执行器会请求阶段停止并等待；不要强制关机或杀进程来模拟正常停止。意外中断后，执行器将未完成任务标为 interrupted、实际结果未知并阻止新提交，管理员须检查原进程和节点。不能删除占用记录、修改回执指纹或更换状态目录绕过保护。

恢复时使用任务详情显示的 root 私有配置路径、原发布代码和原回执，通过 [维护手册](operations.md) 核查。Web 不自动恢复、重试、清理或重新部署。

## 接口与验证边界

新增本机任务接口为 GET `/api/execution`、POST `/api/jobs/preview`、POST `/api/jobs`、GET `/api/jobs`、GET `/api/jobs/{id}`、GET `/api/jobs/{id}/logs?offset=N` 与 POST `/api/jobs/{id}/stop`。提交体为 `{request_id, plan_id, config_sha256, acknowledged, credentials, debug}`，其中 `acknowledged` 必须为 `true`，`debug` 为布尔值；不再有 `confirmation` 文本字段。它们沿用令牌、Host 和同源 Origin 校验。默认未配置执行器时任务接口不可用；既有 validate/plan 的 `execution_authorized=false` 与 `live_checks_performed=false` 不变。

本修订的 Web 执行通过隔离配置、临时目录、HTTP 契约测试与假后端回归验证；没有因此新增真实节点部署、SSH 公钥分发、系统重启或 HA 实机验收结论。历史 CLI 实机结果也不能直接替代本版 Web 完整实机验收。接收方应在获批的新环境独立完成两种入口的现场验收。测试记录由交付方内部保管，公共包只保留程序和用户手册。
