# 维护与故障处理手册

适用交付：20261115-r6（工程化收敛版）。已有集群始终以原部署目录、原配置、实际身份和回执为准；不能用新包覆盖原目录后直接继续运行。以下命令是接收方审查和批准相应维护操作后的参考，不是收包校验步骤。

## 先判断状态和权限

`status` 仅读取本地记录，不 source env、不连接节点：

```bash
bash deploy.sh status
# 使用自定义 STATE_DIR 时，填写状态基础路径而非 .workflow/.deployment 后缀：
bash deploy.sh status --state-dir /srv/rise-state/site-a
```

若原记录由 root 保管，由获授权管理员以 sudo 执行相同只读命令。无权遍历目录或读取记录时，status 明确报告状态未知/读取失败并返回非零；不要将它解释为没有集群。无需 root 的含义是操作不强制提权，不是可以绕过文件权限。即使没有本地记录，也不能排除其它工具部署的集群。

状态记录不是实时健康。需要实时检查时，先按 [配置衔接说明](configuration-workflow.md) 明确 CONFIG 路径和读取身份，再使用原环境匹配的代码：

```bash
CONFIG=/srv/rise-config/site-a.env
sudo bash deploy.sh verify --env "$CONFIG"
```

`verify` 会连接声明节点。不要为检查状态而运行 all、prepare、reset 或修改回执。

## 备份与运行资料

维护前独立保留以下资料，并检查备份可读、归属明确及恢复方案：

| 资料 | 用途与保护 |
| --- | --- |
| 原版代码、原包和摘要 | 与回执中的项目/执行代码指纹对应；新版本不能伪装成原版本 |
| 现场 env、初始化 effective 配置、state/ 和 runs/ | 配置、机器身份、阶段状态和恢复证据；按原所有者和私有权限保管 |
| etcd 快照、节点 K8s/etcd 配置与证书 | 集群恢复；应包含 `/etc/kubernetes`、`/etc/ssl/etcd` 等实际现场路径 |
| WORK_DIR/pki、仓库证书和必要凭据 | 保持原信任关系，不放入公共交付包或普通台账 |
| PV、业务数据库、Harbor 存储与其它数据 | 按业务一致性要求备份；工具保留目录不等于完成备份或可恢复验证 |
| 日志、停止锁、失败节点与已完成阶段清单 | 故障定位与恢复；不得为了续跑删除或重写 |

配置和记录常为 0600 文件、0700 目录。使用有权限的管理员读取，不递归 chmod/chown 生产目录，也不把带密码的 inventory、完整配置、私钥或 kubeconfig 附在普通工单中。对外排障使用人工核对过的摘要和明确错误；工具日志本身不再自动脱敏。

## 中断与续跑

阶段失败后立即保留报错及当前进度。SSH 失联、I/O 错误或监控中断时，先恢复可观测性，再核对所有节点身份、内存、磁盘/挂载和日志；不能通过重启、重新 prepare 或删除停止锁代替根因处理。

只有原配置、代码、机器身份与已有证据仍匹配的未完成部署，才评估“维护与恢复 → 继续上次部署”或 resume：

```bash
CONFIG=/srv/rise-config/site-a.env
sudo bash deploy.sh resume --env "$CONFIG"
```

resume 会进行真实检查并可能继续修改节点；不忽略错误、不自动迁移未知旧回执。配置/代码指纹变化、未完成扩容或存储初始化中断必须先审查，不能重写 fingerprint、改集群名或更换 STATE_DIR 绕过。已完成集群不要为验证新代码重跑首装；已 reset 的集群使用专用 redeploy 流程。

续跑只接受状态为 `running` 或 `interrupted` 的回执；状态文件缺失、不可读、内容未知、`complete` 或 `reset` 都会拒绝续跑，须由管理员按原记录判断处理。

## 清理与重新部署

reset 会删除受管 K8s/etcd 并清空 etcd 数据，禁止 `-y`；先确认备份和操作范围，再生成预览：

```bash
CONFIG=/srv/rise-config/site-a.env
sudo bash deploy.sh reset --env "$CONFIG" --preview
```

预览生成新的本地运行资料，不连接节点或卸载；仍须有权读取原配置和回执。实际清理使用去掉 `--preview` 的同一命令，并按提示核对确认串；不要把此命令当作新环境准备步骤。

明确影响：Harbor、容器运行时、PV 数据目录、离线制品、挂载和 `WORK_DIR/pki` 保留；**节点 `/etc/kubernetes` 与 `/etc/ssl/etcd` 会删除**。reset 还会清空 IPv4 filter/nat 表规则和 IPVS 服务，并可能重启容器运行时及 Harbor。共享宿主上的非 K8s 网络和应用可能受影响，必须单独审查。保留目录不证明业务数据可恢复，也不等于清理过程不会短暂影响服务。

完成 reset 且回执一致后，用专用 redeploy 先预览。仅允许在原基础配置上调整受支持的 Kubernetes 版本和离线制品；其它基础参数仍受原记录约束：

```bash
CONFIG=/srv/rise-config/site-a.env
sudo bash deploy.sh redeploy --env "$CONFIG" --preview
```

确认预览、离线制品和现场条件后，才去掉 `--preview` 进入交互重建。实际开始重建时会归档旧的 `<STATE_DIR>.workflow` 阶段记录（重命名保留，不删除），避免 reset 前的 succeeded 记录被新流程当作已完成阶段复用。不要以旧阶段成功记录重新运行 all/install，也不要将 reset 后的状态当成普通失败直接 resume。真实维护操作的支持范围与限制见 [前置条件手册](deployment-checklist.md)。

## worker 扩容

使用匹配原回执的项目，新增清单只包含 worker；节点名称/IP/身份不能与原集群重复。配置来源须可信，因为新增节点 env 也由 Bash source。

```bash
sudo bash deploy.sh add-workers --state-dir /srv/rise-state/site-a --nodes /srv/rise-config/workers-new.env --preview
```

预览不连接节点；实际扩容须审阅原集群健康、回执兼容性、制品平台/版本、新节点数据和接入后再去掉 `--preview`。未完成扩容按日志和原状态人工审查，不直接重复 all 或删除 `.expansion` 记录。扩容不是新增控制平面或通用拓扑迁移接口。

## 常见故障定位

| 现象 | 下一步 |
| --- | --- |
| CONFIG 为空或文件不存在 | 核对实际导出/向导路径；新 shell 重新赋值，Web 保存草稿不等于导出 |
| 读取权限失败、status 状态未知 | 使用有权读取原配置和状态目录的身份；不把失败变成空记录结论 |
| 私公钥不匹配、孤立公钥、受限授权冲突 | 保留原密钥和 key-policy.log，经可信渠道核对；不删旧授权或追加无限制公钥绕过限制 |
| SSH 主机公钥变化 | 核对主机身份和地址变更；不要自动删除 known_hosts |
| 仓库或镜像验收失败 | 检查域名/CA、公开项目、对应版本和架构摘要；不跳过 TLS 或验收阶段 |
| I/O 错误、内存不足、节点监控失联 | 停止后续操作，保留停止锁和已完成阶段，恢复全节点可观测性后核验根因 |
| 功能验收失败留下临时资源 | 依据证据和 UID 核对归属后单独处理；不强删 finalizer、PV 或数据目录 |

CLI 侧排障可使用 `bash deploy.sh <阶段> --env <配置> --debug`；调试输出包含完整命令与敏感值，只在本机受控终端使用。分步阶段、报告字段和恢复依赖见 [高级分步参考](staged-install.md)。接收方环境的备份恢复、容量、重启和高可用应另行安排验收，不能由静态计划或本地历史记录推断通过。

## 自带根 CA（BYO CA）

默认由 KubeKey 生成自签名根 CA，并据此签发 Kubernetes、etcd 和 Harbor 证书。需要复用企业根证书时，只支持通过控制端路径显式提供根证书与私钥，不接收浏览器上传或证书正文：

1. 同时设置 `PKI_ROOT_CERT`（公开根证书 PEM）和 `PKI_ROOT_KEY`（无口令私钥 PEM），只填一项会被拒绝。
2. 正式安装、resume 或 redeploy 在调用 KubeKey 前，由 root 校验证书自签名、`CA:TRUE`、未过期、私钥未加密且与证书匹配，并要求私钥权限为 0400/0600；校验通过后复制到 `WORK_DIR/pki/root.crt`、`root.key`，渲染时固定 `certs.ca.gen_cert_policy=IfNotPresent`。
3. 已有 `WORK_DIR/pki/root.crt`/`root.key` 必须与提供的根 CA 完全一致，否则拒绝安装；不能在已有集群上中途更换根 CA。
4. `HARBOR_CERT`/`HARBOR_KEY` 仍不参与签发，仅 `PKI_ROOT_*` 影响整条证书链。根 CA 规划、备份和轮换须与集群 PKI 一并管理。

## Web 部署任务的故障处理

Web 首装执行器保存提交时配置、集群占用记录和未脱敏任务日志，CLI 另保存阶段回执及原始日志。任务详情中的 `config_path`、`state_dir`、`work_dir` 是实际路径；由管理员读取原配置，不能从修改后的草稿重新首装。

- 页面超时或断线：重新连接同一服务，刷新任务列表或按原任务 ID 查询；不要重新创建部署。关闭网页不停止任务。
- 任务日志不做脱敏，可能含密码、私钥路径与完整命令；页面默认 Info，可切 Debug。日志与执行器目录按凭据材料保管，不要随公开工单或截图外发。需要更多追踪时，在提交前勾选“以调试模式运行”重新执行（不要对已完成集群重跑首装来“复现”问题）。
- 请求停止：仅在当前阶段结束后阻止下一阶段，不会撤销已经执行的操作，也不会强制终止远端进程。只有任务进入最终状态后再核查实际节点。
- 失败或已停止：保留配置、回执、工作目录、日志、PKI 和数据，由管理员按本手册核对后使用原 CLI 维护。Web 不自动重试，也不提供恢复或清理按钮。
- 执行器意外退出：重启时未完成任务标记为中断、结果未知，并阻止新任务；可能仍有 CLI 或远端操作运行。先检查进程和节点，不能根据旧 PID 自动杀进程，也不能删除占用记录或改集群名绕过保护。

执行器目录只允许 root 读取；原 CLI inventory、状态和日志可能含认证资料，按凭据保管并受控备份，禁止随公开交付包或普通问题截图外发。Web 提供的任务日志是辅助视图，不能替代管理员审阅完整回执。启动和权限配置见 [Web 部署指南](web-deployment.md)。
## 统一 CLI/Web 入口与阶段接管

CLI 与 Web 执行器现在统一落到 `lib/workflow.sh`、`lib/cluster-state.sh` 和同一份
`STATE_DIR` 阶段记录；Web 不维护私有阶段枚举，也不直接调用 KubeKey。

```bash
# 显式 CLI（无 --step 时进入 CLI 菜单）
sudo ./deploy.sh cli

# 使用已有可信 env 做非交互执行；不会伪造默认节点或自动格式化
sudo ./deploy.sh cli --auto-default --env /absolute/site.env -y

# 从已完成阶段边界接管/重试；阶段名与 flow 的步骤一致
sudo ./deploy.sh cli --step services-verify --env /absolute/site.env
sudo ./deploy.sh cli --step cluster-verify --env /absolute/site.env
```

Web 页面停止只写阶段边界标记；任务结束后由管理员用同一 `STATE_DIR` 的 CLI
`--step` 或 `resume` 处理。Web 任务日志和 CLI 日志都不是脱敏材料。
Web 不再提供手动 SHA256 交互；后端按归档路径读取同目录 `.sha256` 或
`artifact/SHA256SUMS`，部署时 CLI 仍校验实际字节。CLI 的
`./deploy.sh artifact-sha256 --file /absolute/archive.tgz` 供可信管理员本地计算。

Web 任务详情的“下载环境台账”按钮读取执行器管理的最近一次
`k8s_harbor_deployment_inventory.xlsx`（兼容 `environment-ledger.xlsx`）；CLI 使用
`./deploy.sh ledger --env ...`，两者都调用 `lib/ledger.py`，不包含密码。

## KubeKey（kk）版本升级 SOP

随包二进制只允许存在于 `tools/amd64/kk` 与 `tools/arm64/kk`；根目录不再存放
`kk-amd`/`kk-arm`。版本摘要表为 `lib/kk-binaries.sha256`，格式为
`<sha256>  tools/<arch>/kk  <version>`。

1. 在联网供应商控制端执行：
   ```bash
   ./tools/kk-fetch.sh --version v4.0.x --apply
   ```
   工具只下载官方 Linux Release，校验摘要后写入 `tools/<arch>/kk`；不会恢复根目录副本。
2. 更新 `cluster-vars.env` 的 `KK_VERSION`，并按 `docs/kubekey-4.0.10.md` 对
   `playbooks/`、标准 `roles/`、`defaults/config/vX.Y.yaml` 做差异评审。
3. `roles/rise/` 是本项目扩展，不随上游替换；只替换上游 playbook/标准 role。
4. 执行 `tests/` 与 `deploy.sh config-check/plan`，重新生成 `SHA256SUMS`、
   `SOURCE_SHA256SUMS` 和外层归档；切换版本必须重新验收离线制品与模板差异。
5. `--check` 只核对 `tools/<arch>/kk`；发现摘要不一致时停止，不修改表来“修复”现场。

## 新增 Kubernetes 版本与离线制品 SOP

版本列表不是 Shell/Python 常量，而是扫描 `configs/v*.yaml`：

- `lib/kubernetes-versions.py list/default` 供 CLI 使用；
- `web/config_model.py` 的 `schema()` 动态填充 Web 的版本枚举；
- `lib/offline-audit.py` 从同一 `configs/` 目录选择默认版本。

新增步骤只有三步：

1. 新增 `configs/vX.Y.Z.yaml`，文件名必须与文件内 `kube_version` 完全一致，
   并与 `kk-project/defaults/config/vX.Y.yaml` 对齐。
2. 放入该版本 `artifact/kubekey-artifact.tgz` 与 `artifact/manifests.yaml`；
   运行 `tools/artifact-refresh.sh`（或 `tools/refresh-checksums.sh`）更新
   `artifact/SHA256SUMS`，再运行
   `python3 lib/offline-audit.py --root . --output <new-dir> --kubernetes vX.Y.Z --arch <amd64|arm64>`。
3. 运行 `tests/test_version_discovery.py`、`tests/test_offline_audit.py` 和
   `./deploy.sh --versions`；不需要改业务 Shell/Python 的版本分支。

任意版本/架构缺 ISO、镜像、二进制或 manifest 时，`offline-audit.py` 必须报告 blocker，
不能用“文件存在”代替摘要、依赖闭包或实机验收。

## 新增操作系统与 bootstrap 离线包 SOP

统一命名：`bootstrap-<distro>-<arch>.tar.gz`，旁边必须有同名
`.sha256`；`distro` 使用 Ubuntu codename（`jammy`、`noble`）或 Kylin
`ky10`；`arch` 使用 `amd64`、`arm64` 或 Kylin 现场约定的 `aarch64`。

1. 在目标 OS 的干净环境制作离线包，包内包含 `Packages`/deb 或
   `repodata`/rpm 以及 `SHA256SUMS`；运行
   `python3 lib/bootstrap-route.py --os-release /etc/os-release --machine $(uname -m) --bootstrap-dir bootstrap`
   验证路由候选。
2. 更新 `docs/bootstrap-packages.json` 的 `variants` 清单，记录发行版、
   codename、arch、文件名和来源/摘要；不要把密码或私钥写入清单。
3. `node_scripts/probe.sh` 输出 `RISE_PROBE_ID`、`VERSION_CODENAME`、
   `RISE_PROBE_ARCH` 和包管理器；`node_scripts/deps.sh bootstrap <目录或归档>`
   自动匹配并走 apt 本地源或 yum/dnf + createrepo 本地仓库。CLI 设置
   `DEPS_MODE=bootstrap`，可选 `BOOTSTRAP_ARCHIVE=/绝对路径`；留空时
   `lib/artifact.sh` 会按节点 `NODE_OS`/`NODE_ARCH` 从 `bootstrap/` 自动选择并上传。
4. 控制端安装使用 `sudo ./deploy.sh bootstrap [--with-sshpass]`；它会拒绝
   不匹配的 OS/arch，不静默回退外网。
5. 更新 `bootstrap/install.sh` 不涉及业务分支；新增 OS 只需补包、清单、路由
   名称和 `tests/test_bootstrap_router.py` 样例。

## 默认值与存储保护

- 默认拓扑：3 控制平面 + worker/etcd，API 使用 kube-vip，Harbor 单 registry。
- 默认服务：NTP 自建（第一个控制平面为 server，允许本地时间源），NFS 自建
  （第一个控制平面共享 `/data/nfs`）；外部服务通过 `NTP_MODE=external`、
  `NFS_MODE=existing` 覆盖；Harbor HA 使用 `examples/harbor-replica.env`。
- 默认存储：数据根 `/data`；`/var/lib/containerd`、`/var/lib/kubelet`、
  `/data/harbor` 对应 `/data/containerd`、`/data/kubelet`、`/data/harbor`。
- `node_scripts/storage.sh` 和 `storage-path-check.sh` 在创建链接、挂载或格式化前
  检查非空目录、已有链接、运行中 runtime 和已有配置；发现任一残留即暂停。不得
  用删除目录、清空组件或改路径绕过。
- CLI 默认值从 `web/schema.json` 读取（`lib/schema-defaults.py`）；修改默认值只改
  schema，并同步 examples/docs 的现场说明，不在 Shell/Python 新增第二套常量。

## 回归与发布检查

```bash
python3 -m unittest discover -s tests -v
bash -n deploy.sh lib/*.sh node_scripts/*.sh bootstrap/install.sh tools/*.sh
./tools/refresh-checksums.sh
```

发布前还必须核对 `SHA256SUMS`、`SOURCE_SHA256SUMS`、`artifact/SHA256SUMS`、
`bootstrap/*.sha256` 和外层归档摘要；测试目录、开发补丁脚本和凭据不得进入
公开交付。完成后按现场审批删除 Lima VM、VM 备份和数据盘，不要删除业务数据。
