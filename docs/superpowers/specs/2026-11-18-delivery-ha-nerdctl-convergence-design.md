# KubeKey v4.0.10 交付套件：Master/Etcd 奇数高可用、K8s 节点 nerdctl 预置与全链路工程收敛设计规格

- **日期**：2026-11-18
- **状态**：已获用户确认（含补充的 K8s 节点前置安装 `nerdctl` 及配置需求）
- **存放路径说明**：本规格与实施计划位于外层仓库 `docs/superpowers/`，不进入 `delivery-v4.0.10/` 交付包目录，确保不污染客户侧 `SOURCE_SHA256SUMS` / `SHA256SUMS`。

---

## 1. 目标与全局约束

### 1.1 目标
在完全保持现有安全边界（特权分离、无 Shell 执行导入、阶段边界柔性停止、回执指纹防篡改）与零第三方运行时依赖的前提下，一次性闭环以下五项工程升级：
1. **Master 与 Etcd 同机正奇数高可用（1 / 3 / 5 / 7…）**：杜绝偶数节点（如 2、4）或 Master/Etcd 错位带来的 Raft 脑裂与法定人数退化；多 Master（≥3）强制要求 VIP 或外部负载均衡。
2. **K8s 节点前置预装 `nerdctl` 与 `/etc/nerdctl/nerdctl.toml`**：新增 `INSTALL_NERDCTL`（默认 `true`，Web 界面默认勾选），在节点前置准备阶段为所有 K8s 节点（`control_plane` / `worker`，含扩容新增节点）解压 `artifact/tools/{amd64,arm64}/nerdctl-2.2.1-linux-{amd64,arm64}.tar.gz` 到 `/usr/local/bin` 并生成配置（`namespace = "k8s.io"`、`cgroup_manager = "cgroupfs"`、`hosts_dir`）。
3. **前后端配置契约单一真相源**：补齐 `web/schema.json` 缺失高级字段，将显隐规则下沉为 `visible_when` 属性，彻底修复 Web 端 `external-harbor` / `COMPONENTS=k8s` 字段误删与 `COMPONENTS=harbor` 0-Master 误拦两个高优 Bug。
4. **BYO CA 回执补齐、状态机加固与运维后置验收闭环**：补全 `PKI_ROOT_*` 回执路径持久化，修复 `workflow.sh` 遗留状态名，收紧 Web 分阶段重入条件，并让 `redeploy` 与 `scale-worker` 完成后自动同步 `.workflow` 快照并跑通 `node-images-verify` → `cluster-verify` → `ledger`。
5. **节点受控并发、日志精确掩码/头尾保留与发布防呆**：落实 `SSH_PARALLEL` 并发执行器 `node_run_parallel`，升级 `JobLog` 支持内存密码精确掩码与 1 MiB 头 + 3 MiB 尾双段保留，配套全量契约测试与一键清单刷新脚本 `release.sh`。

### 1.2 全局约束
- 控制端语言与依赖：Linux 控制端要求 Bash ≥ 4.4 + `jq` + Python 3.8+ 标准库；Web 后端与台账仅使用 Python 标准库；前端为无构建步骤的原生 ES6 + CommonJS 纯逻辑层。
- 兼容性要求：保留现有 67 个 Python 单测语义（如无凭据注入时 `JobLog()` 不做启发式正则替换）；不现场重新打包 6.7 GiB 外层 `.tar.gz`，但必须保证 `delivery-v4.0.10/` 内所有摘要清单（`SOURCE_SHA256SUMS`、`SHA256SUMS`、`artifact/SHA256SUMS`）100% 校验通过且无 `__pycache__`/`._*` 残留。

---

## 2. 模块详细设计

### 2.1 模块 1：Master/Etcd 正奇数高可用与 Schema 单一真相源
1. **Master/Etcd 正奇数同机规则**：
   - `delivery-v4.0.10/lib/config.sh`：
     - 当 `COMPONENTS != harbor` 且 `VALIDATION_SCOPE != workers` 时：`CONTROL_PLANES` 数量必须满足 `count >= 1 && count % 2 == 1`（报错文案：`master 与 etcd 数量必须为 1、3、5 等正奇数，避免高可用脑裂`）；保持 `etcd` 与 `control_plane` 同机一一对应；当 `count >= 3` 时，`ENDPOINT_TYPE` 禁止为 `local`（须为 `kube-vip` 或 `external` 且填写 `ENDPOINT_ADDRESS`）。
   - `delivery-v4.0.10/lib/wizard-nodes.sh` 与 `delivery-v4.0.10/lib/wizard.sh`：
     - `wizard_nodes_valid` 改为校验 `masters >= 1 && (masters % 2) == 1`；`wizard_setup` 中将 `masters == 3` 的判断统一改为 `masters >= 3`。
   - `delivery-v4.0.10/web/config_model.py`：
     - 新增 `validate_topology(config)` 可选辅助函数供单测与服务层复用，与 CLI 规则严格一致。
   - `delivery-v4.0.10/web/static/workbench-logic.js` 与 `app.js`：
     - 新增纯函数 `validateMasterEtcdTopology(nodes, components)`：
       - 若 `components === 'harbor'`，返回 `{valid: true, masterCount: 0, etcdCount: 0, coLocated: true, reason: ''}`（修复纯 Harbor 0-Master 锁死问题）。
       - 否则统计 `masterCount`、`etcdCount` 及每节点 `hasMaster === hasEtcd`：若存在不一致，返回 `Master 与 Etcd 必须同机一一绑定`；若 `masterCount < 1 || masterCount % 2 === 0`，返回 `Master/Etcd 节点数量必须为 1、3、5… 正奇数（当前为 N），偶数节点存在高可用脑裂风险`。
     - 节点矩阵交互联动：勾选/取消 `Master`（`control_plane`）时自动同步添加/移除同行的 `Etcd`（`etcd`）；点击 `Etcd` 时同样同步切换 `Master`，并在标签注明 `Etcd（随 Master 同机）`；克隆节点或新增节点时自动维持该不变式；`masterCount >= 3` 时强制要求 `ENDPOINT_ADDRESS` 并将 `local` 自动切换为 `kube-vip`。
2. **Schema 补齐与 `visible_when` 声明式下沉**：
   - 在 `delivery-v4.0.10/web/schema.json` 新增字段：
     - `INSTALL_NERDCTL`（`cluster` 组，`boolean`，默认 `true`）
     - `ZONE`（`advanced` 组，`string`，默认 `"cn"`）
     - `PKI_ROOT_CERT`、`PKI_ROOT_KEY`（`advanced` 组，`string`，默认 `""`）
     - `SSH_KNOWN_HOSTS`、`SSH_KNOWN_HOSTS_SHA256`（`access` 组，`string`，默认 `""`）
   - 在 `config_model.py` 中将 `PKI_ROOT_CERT`、`PKI_ROOT_KEY`、`SSH_KNOWN_HOSTS` 加入 `_PATH_KEYS`，将 `SSH_KNOWN_HOSTS_SHA256` 加入 `_DIGEST_KEYS`。
   - 在 `schema.json` 各受控字段上定义 `visible_when` 对象，前端 `app.js` 通过 `logic.schemaRules(state.schema)` 自动构建规则映射，移除硬编码 `RULES`：
     - `REGISTRY_MODE`、`HARBOR_DOMAIN`、`HARBOR_PORT`、`HARBOR_HTTP`：对所有 `COMPONENTS`（`all`、`harbor`、`k8s`）均可见（`k8s` 模式下需要指定复用仓库模式与域名端口，不再被 `pruneConfig` 删除）。
     - `IMPORT_IMAGES`：`{all: [{field: 'COMPONENTS', in: ['all', 'harbor']}, {field: 'REGISTRY_MODE', notEquals: 'external-harbor'}]}`。
     - `HARBOR_ADDRESS`：`{field: 'REGISTRY_MODE', equals: 'external-harbor'}`。
     - `HARBOR_CA`：`{any: [{field: 'REGISTRY_MODE', equals: 'external-harbor'}, {field: 'COMPONENTS', equals: 'k8s'}, {field: 'HARBOR_HTTP', equals: false}]}`（任何 HTTPS 场景均保留用户填写的 `HARBOR_CA`）。
     - `HARBOR_VIP`、`HARBOR_VRRP_ID`：`{all: [{field: 'COMPONENTS', in: ['all', 'harbor']}, {field: 'REGISTRY_MODE', equals: 'ha-harbor'}]}`。
     - `HARBOR_SOURCE_DIR`：`{all: [{field: 'COMPONENTS', in: ['all', 'harbor']}, {field: 'REGISTRY_MODE', notEquals: 'external-harbor'}]}`。
     - `INSTALL_NERDCTL`：`{field: 'COMPONENTS', in: ['all', 'k8s']}`。
   - 在 `workbench-logic.js` 的 `ruleVisible` 中补充 `rule.any` 支持（与现有 `rule.all` 对称）。

### 2.2 模块 2：K8s 节点前置安装 `nerdctl` 与 `/etc/nerdctl/nerdctl.toml`
1. **配置与渲染链路**：
   - `lib/config.sh`：`load_env` 默认 `: "${INSTALL_NERDCTL:=$(schema_default INSTALL_NERDCTL)}"`（即 `true`），`validate_env` 校验布尔值 `true|false`。
   - `lib/cluster-state.sh`：`write_cluster_env` 持久化 `INSTALL_NERDCTL`。
   - `cluster-vars.env.example` 与 `web/static/app.js`（`BASIC_KEYS`）：暴露 `INSTALL_NERDCTL=true`，Web 第 1 步默认勾选。
   - `lib/render.sh`、`config-base.yaml` 与 `kk-project/roles/rise/verify/tasks/main.yaml`：渲染 `rise.install_nerdctl: ${INSTALL_NERDCTL}`；当 `INSTALL_NERDCTL=true` 时执行 `rise/verify` 中的 `nerdctl` 校验步骤，`false` 时仅执行 `crictl` 校验。
2. **前置脚本与归档寻址**：
   - 新增幂等节点脚本 `delivery-v4.0.10/node_scripts/nerdctl.sh`：
     - 支持测试沙箱前缀变量 `NERDCTL_DEST_ROOT="${NERDCTL_DEST_ROOT:-}"`（生产为空，即 `/usr/local/bin` 与 `/etc/nerdctl`）。
     - 识别节点架构（`x86_64|amd64` → `amd64`，`aarch64|arm64` → `arm64`）。
     - 若目标路径尚无可用 `nerdctl`：将传入的归档（如 `/etc/kubekey/rise/nerdctl.tar.gz`）解压到 `${NERDCTL_DEST_ROOT}/usr/local/bin`，确保 `chmod 0755 .../nerdctl`，并清理临时归档包。
     - 若 `${NERDCTL_DEST_ROOT}/etc/nerdctl/nerdctl.toml` 不存在：创建 `${NERDCTL_DEST_ROOT}/etc/nerdctl`（`0755`）并写入（`0644`）：
       ```toml
       namespace      = "k8s.io"
       cgroup_manager = "cgroupfs"
       hosts_dir      = ["/etc/containerd/certs.d", "/etc/docker/certs.d"]
       ```
   - 在 `delivery-v4.0.10/lib/artifact.sh` 新增 `resolve_nerdctl_archive <arch>` 与 `install_k8s_nodes_nerdctl`：
     - 优先定位 `$(dirname "$ARTIFACT_FILE")/tools/<arch>/nerdctl-2.2.1-linux-<arch>.tar.gz`，若 `ARTIFACT_FILE` 为空（如 `preinstalled` 模式）则回退 `$ROOT/artifact/tools/<arch>/nerdctl-2.2.1-linux-<arch>.tar.gz`，并核对同级 `SHA256SUMS` 摘要，杜绝损坏或被篡改二进制下发。
     - 当 `INSTALL_NERDCTL=true` 且 `COMPONENTS != harbor` 时，遍历活动清单中所有含 `control_plane` 或 `worker` 角色的节点，上传对应架构归档至 `/etc/kubekey/rise/nerdctl.tar.gz` 并调用 `node_scripts/nerdctl.sh`。
     - 在 `init.sh`（节点初始化完成前）与 `prepare_dependencies`（`deps` 阶段及 `scale-worker.sh` 扩容依赖准备）中均调用 `install_k8s_nodes_nerdctl`，确保无论走单步 `init`、`prepare`、`deps`、`all` 还是 `add-workers`，所有 K8s 节点在前置阶段即完成 `nerdctl` 与配置预置。

### 2.3 模块 3：BYO CA 回执、状态机加固与运维后置验收统一
1. **BYO CA 回执持久化**：
   - `lib/resume.sh`：`resume_pki` 与 `resume_save_receipt` 中将证书变量列表扩展为 `HARBOR_CA HARBOR_CERT HARBOR_KEY PKI_ROOT_CERT PKI_ROOT_KEY`。
   - `lib/prepared-config.sh`：`load_maintenance_env` 同步恢复 `PKI_ROOT_CERT` 与 `PKI_ROOT_KEY`。
2. **状态机修复**：
   - `lib/workflow.sh:32`：将 `[ ! -f "$WF_DIR/access.status" ] || [ "$(cat "$WF_DIR/access.status" ...)" != succeeded ]` 修正为 `[ "$(workflow_status access)" != succeeded ]`。
   - `web/execution.py`：`submit()` 中 `is_continuation` 要求：
     - `prev_job` 存在且 `state` 不在 `ACTIVE` 且不为 `'interrupted'`；
     - `prev_job.get('config_sha256') == plan['config_sha256']`（配置哈希不一致时返回 `409 config_changed_between_stages`）；
     - `not (prev_job.get('stage') in ('all', 'k8s') and prev_job.get('state') == 'succeeded')`（整套或末阶段已成功完成后拒绝重入首装）。
3. **运维后置验收与 `.workflow` 快照收敛**：
   - 新增 `delivery-v4.0.10/lib/post-verify.sh`（定义 `workflow_sync_and_post_verify`）：
     - 在 `redeploy`（`deploy.sh` `redeploy-run` 成功后）与 `scale-worker.sh`（扩容 `record_cluster_state` 成功后），若未显式传入 `--skip-post-verify`（或 `SKIP_POST_VERIFY=true`）：
       1. 以最新生效配置和全量节点检查摘要原子更新 `${STATE_DIR}.workflow/` 下的 `effective.env`、`effective.sha256`、`identity.json`、`identity.sha256` 与 `fingerprint`，并将前置已完成安装阶段同步标记为最新指纹下的 `succeeded`；
       2. 自动依次执行 `node-images-verify`、`cluster-verify`（HTTPS Harbor 下）和 `ledger`，输出覆盖全量节点的最新台账。

### 2.4 模块 4：受控并发 `node_run_parallel` 与 `JobLog` 增强
1. **`node_run_parallel`**（`delivery-v4.0.10/lib/common.sh`）：
   - 接口：`node_run_parallel <label> <lines_input_var_or_cmd> <worker_fn>`（按 `${SSH_PARALLEL:-5}` 限制最大并发子进程数，每个节点子进程在独立子目录记录退出码与输出，主进程保序汇总日志并校验全部退出码为 0，任一失败立即返回非零）。
   - 应用点：`workflow_write_hosts`（写 `/etc/hosts`）、`component_sync_registry_ca`（同步 Harbor CA）、`init.sh` 内核参数下发（`kernel.sh`）以及 `install_k8s_nodes_nerdctl`（并发上传安装 `nerdctl`）。
2. **`JobLog` 精确密码掩码与头尾保留**（`delivery-v4.0.10/web/execution.py`）：
   - `JobLog(secrets=None)`：过滤空串并按长度降序保存非空凭据字符串，在 `_plain()` 清洗控制字符后将每个秘密字面量替换为 `[REDACTED]`；`ExecutionService._run` 在创建 `JobLog` 时传入当前任务的密码值列表（`HARBOR_PASSWORD` 与各节点 SSH 密码）。
   - 头尾双段保留（总容量上限不变，仍为 `MAX_LOG = 4 MiB`）：
     - `HEAD_LOG_BYTES = 1 * 1024 * 1024`（1 MiB），`TAIL_LOG_BYTES = 3 * 1024 * 1024 - 256`（约 3 MiB）。
     - 未超 `MAX_LOG` 时线性追加写入 `output.log`；超出后保留头部 1 MiB + 动态提示行 `[日志已超过 4 MiB 上限；中间省略 N 字节，以下保留最新尾部输出]\n` + 最新 3 MiB 完整行尾部内容，同时记录单调递增的虚拟流偏移 `total_emitted` 供 `logs(id, offset)` 平滑续读而不报 `invalid_offset`。

### 2.5 模块 5：测试矩阵与 `release.sh` 发布脚本
- 新增/扩展单测：
  - `tests/test_ha_and_nerdctl.py`：覆盖 Master/Etcd 1/3/5 正奇数放行与 0/2/4/错位拦截、`INSTALL_NERDCTL` 默认值与 `node_scripts/nerdctl.sh` 在 amd64/arm64 沙箱下的真实解压 + `nerdctl.toml` 生成与幂等性、全量 `examples/*.env` 前后端 `import_env → pruneConfig → export_env` 往返无损性、BYO CA 回执保存恢复、`node_run_parallel` 并发限流与失败传播。
  - 扩展 `tests/test_web.py` 与 `tests/workbench-logic.test.js`：覆盖 `JobLog` 敏感凭据精确掩码、超 4 MiB 头尾双段保留、`is_continuation` 配置哈希/完成态拦截、前端 `validateMasterEtcdTopology` 与 `schemaRules`。
- 新增外层 `/Users/y.q/demo/delivery/release.sh`：
  - 清理 `__pycache__`、`*.pyc`、`._*`、`.DS_Store`；
  - 以 `PYTHONDONTWRITEBYTECODE=1` 运行全量 Python `unittest`、Node `workbench-logic.test.js` 及全仓 `.sh` 的 `bash -n` 语法检查；
  - 调用 `delivery-v4.0.10/tools/refresh-checksums.sh` 刷新 `SOURCE_SHA256SUMS` 与 `SHA256SUMS`，并执行 `shasum -a 256 -c` 校验；支持可选 `--pack` 参数生成外层归档。
