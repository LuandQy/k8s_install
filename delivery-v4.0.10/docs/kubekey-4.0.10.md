# KubeKey v4.0.10 评估与合并记录

适用交付：20261114-r5-dev。本文说明三件事：Harbor 是否由 KubeKey 部署及其证书来源；KubeKey v4.0.10 相对 v4.0.9 修复了什么、哪些是我们的踩坑点；本交付实际合入了哪些修复、如何回退或继续升级。

上游发布：v4.0.10 于 2026-11-13 发布（<https://github.com/kubesphere/kubekey/releases/tag/v4.0.10>）。本交付已于 2026-11-15 随包安装 v4.0.10 二进制；离线制品仍由 v4.0.9 导出，按评估结论不重制。

## 1. Harbor 由谁部署、证书由谁处理

**结论：Harbor 由 KubeKey 部署，证书也由 KubeKey 生成、分发和校验。**

- 入口：[create_harbor.yaml](../kk-project/playbooks/create_harbor.yaml) 对 `image_registry` 组执行 `native/root → defaults → precheck/image-registry → certs/init → download → native/init → native/dns → cri/docker → image-registry`。
- 安装：`image-registry` 角色根据 `image_registry.type=harbor` 引入 `image-registry/harbor`，从离线制品解出官方 `harbor-offline-installer-*.tgz`，渲染 `harbor.yml` 并执行 `prepare`、启动 `harbor.service`。
- 端口：渲染配置把 `HARBOR_PORT` 同时写入 `image_registry.https_port` 和客户端 registry 地址；非 443 端口时 `harbor.yml`、健康检查和 containerd/Docker 信任路径使用同一端口。`http_port` 固定为 80，仅用于 Harbor 的 HTTP 跳转。
- 证书：`certs/init` 用 `WORK_DIR/pki/root.crt` 签发 `image_registry.crt/key`，SAN 包含仓库域名、每个 registry 节点 IP 和 HA VIP；`harbor` 任务把 `image_registry.crt/key` 与 `root.crt` 复制到 `/opt/harbor/<版本>/ssl/{server.crt,server.key,ca.crt}`，`harbor.yml` 的 `https.certificate`、`https.private_key` 指向它们。
- HA：所有实例共用同一份 token 签名密钥对与 `secretkey`（由 `certs/init` 在控制端生成），因此一个实例签发的 token 能被其它实例校验；keepalived 的 VRRP Router ID 在 v4.0.10 起可配置。
- 客户端信任：本工具把该根 CA 复制为 `harbor-ca.pem`，通过 `image_registry.auth.ca_file` 让 containerd/CRI 与 `lib/harbor.sh` 的 curl 信任它；台账和状态目录保存的也是这份公开 CA。
- **我们的 `HARBOR_CERT`/`HARBOR_KEY` 字段目前不参与签发。** 它们被渲染到 `spec.rise.external_cert/external_key`，但没有任何角色消费该字段；`gen_cert` 在 `IfNotPresent` 下会校验既有证书链与 SAN，不匹配就**重新生成**，所以预置 `pki/image_registry.crt` 也会被覆盖。
- **自带根 CA 走独立的可选入口。** 同时设置 `PKI_ROOT_CERT`/`PKI_ROOT_KEY` 后，安装、resume、redeploy 会在调用 KubeKey 前由 root 校验根证书/私钥并复制到 `WORK_DIR/pki/root.crt`/`root.key`，同时把 `certs.ca.gen_cert_policy` 固定为 `IfNotPresent`；已有根不一致时拒绝。它影响 Kubernetes、etcd 与 Harbor 的全部证书，不能中途更换。受管 Harbor 场景仍应保持 `HARBOR_CERT`/`HARBOR_KEY` 为空。

## 2. v4.0.10 修复清单与归类

修复分三类。**关键点：本交付 vendored 了 `kk-project` 模板，绝大多数修复在模板里，不需要换二进制即可生效。**

| PR | 修复内容 | 位置 | 对本交付的意义 |
| --- | --- | --- | --- |
| #3290 | 离线 ISO 包按需逐个解析，而不是一次性求依赖闭包 | 构建侧 `hack/gen-repository-iso` | 只有重制 ISO/制品才生效；已发布制品不变 |
| #3291 | Harbor HA keepalived 的 `virtual_router_id` 可配置 | 模板 | 同一 L2 多套 keepalived 时避免 VIP 抖动 |
| #3292 | docker-registry 数据目录持久化到宿主机 | 模板 | 本交付不暴露 docker-registry 模式，未合入 |
| #3294 | etcd 备份脚本使用 `ETCD_ENDPOINTS`，修复未定义变量 | 模板 | **踩坑点**：备份脚本会直接失败 |
| #3296 | 证书续期脚本 shebang 粘连、systemd ExecStart 路径不一致 | 模板 | **踩坑点**：`k8s-certs-renew` 实际不可用 |
| #3299 | 卸载时删除 cert-renew timer/service/script | 模板 | **踩坑点**：reset 后残留定时器会操作已删除证书 |
| #3302 | containerd static 归档名带 `static-` 标记 | 模板 | 制品与安装选择一致；默认不启用 static |
| #3305 | repository 任务传播包安装器的退出码 | 模板 | **踩坑点**：apt/yum 失败可能被恢复源动作掩盖 |
| #3306 | kubeadm 证书与 CA 有效期可配置 | 模板 | 默认值与 kubeadm 原默认一致，可按需延长 |
| #3297/#3301 | Harbor v2.13.0 离线包构建、按平台 docker save | 构建侧 | 只有重制制品才生效 |
| #3303 | flannel chart 版本按 Kubernetes 版本解析 | 模板 | 本交付 CNI 固定 Calico，未合入 |
| #3307 等 | 依赖升级、CI | 二进制/构建 | 随二进制发布 |

## 3. 本交付已合入的内容

以下文件与 v4.0.10 逐字节一致（`kk-project` 内）。它们在 v4.0.9 二进制下也已验证兼容（`ternary`、`semverCompare`、`regexMatch` 均存在于 v4.0.9），当前随包 v4.0.10 原生支持：

| 文件 | 来源 | 作用 |
| --- | --- | --- |
| `roles/etcd/install/templates/backup.sh` | #3294 | etcd 备份可用 |
| `roles/kubernetes/certs/files/k8s-certs-renew.service` | #3296 | ExecStart 指向真实脚本 |
| `roles/kubernetes/certs/templates/renew_script.sh` | #3296 | 修复 shebang 与条件渲染粘连 |
| `roles/uninstall/kubernetes/tasks/kubernetes.yaml` | #3299 | reset 清理续期单元 |
| `roles/defaults/defaults/main/02-image_registry.yaml` | #3291 | 新增 `virtual_router_id: 31` |
| `roles/image-registry/keepalived/templates/keepalived.conf` | #3291 | 使用可配置 VRID |
| `roles/defaults/defaults/main/03-kubernetes.yaml` | #3306 | 证书有效期字段 |
| `roles/kubernetes/init-kubernetes/templates/kubeadm/kubeadm-init.v1beta4` | #3306 | `certificateValidityPeriod`/`caCertificateValidityPeriod` |
| `roles/cri/containerd/tasks/main.yaml` | #3302 | static 归档名一致 |
| `roles/defaults/defaults/main/10-download.yaml` | #3302 | static 变体进入下载项 |
| `roles/download/tasks/binary.yaml` | #3302 | 打包时同时准备两种变体 |
| `roles/download/package/tasks/binary.yaml` | #3302 | 同上 |

**手工合并（比上游更严格）**：`roles/native/repository/tasks/install_package.yaml` 采用 v4.0.10 的“保存安装器退出码 + 恢复源 + 再上报”结构，同时保留原有的逐包安装校验。两者都失败才报错，报错时能指出具体缺包，也能发现“包都在但安装器异常退出”的中间态。

**未合入**：docker-registry 持久化（#3292，本交付无该模式）与 flannel 默认版本（#3303，CNI 固定 Calico）。如后续启用这些模式，需要同步升级二进制并补对应模板。

## 4. 与本交付自有保护的关系

- 我们的 `verify_artifact` 仍独立校验离线制品成员与摘要；模板修复不改变该边界。
- `reset.sh` 会在 reset 前备份节点准备元数据；v4.0.10 的卸载清理是额外保障，不替代备份与确认串。
- 证书续期模板修复后，仍需现场验证 `systemctl list-timers k8s-certs-renew` 与一次手工触发；台账不因此声称已验收。
- keepalived VRID 新增 `HARBOR_VRRP_ID`（1–255，默认 31），只在 `REGISTRY_MODE=ha-harbor` 生效；配置写入生效快照并参与工作流指纹。

## 5. 升级决定与执行记录（2026-11-15）

决定：随包二进制切换到 **v4.0.10**；**不重制离线制品/ISO**；`tests/` 保留为开发副本，不计入交付清单；日志不脱敏作为已接受风险，打包留待全部就绪后再做。

已执行：

1. `./tools/kk-fetch.sh --version v4.0.10 --apply`：下载官方 amd64/arm64 Release，摘要核对一致后只替换 `tools/<arch>/kk`（根目录不再生成 `kk-amd`/`kk-arm`；v4.0.9 原文件已移出交付树，可用同一条命令回退）。
2. `./tools/kk-fetch.sh --version v4.0.10 --check`：两架构均 OK。
3. 默认值改为 v4.0.10：`cluster-vars.env.example`、`lib/config.sh`、Web schema；`lib/kk-binaries.sha256` 保留 v4.0.9 记录。
4. 重算并复核 `SHA256SUMS` / `SOURCE_SHA256SUMS`。

**制品立场与残余风险**：

- 离线制品是内容仓库（二进制、镜像、ISO），与执行引擎版本解耦；本交付的 `kk-project` 模板已与 v4.0.10 对齐，因此不重制。
- v4.0.10 的 #3290 只修复“重制 ISO 时的依赖解析”，不会给已打包的 ISO 补包。若现场 deps 阶段发现缺包，应停止安装并按需用 v4.0.10 重制 ISO，不能继续。
- 首轮现场验收重点观察 deps（ISO 包解析）、images-import（制品清单）与 k8s-install（引擎行为）；异常时用摘要表回退 v4.0.9。

回退：`./tools/kk-fetch.sh --version v4.0.9 --apply`，并把 `KK_VERSION` 改回 `v4.0.9`。已安装集群维护仍以原回执、原代码指纹为准，不能靠换二进制“兼容”旧回执。

## 6. 验证记录

- 官方 Release `kubekey-v4.0.10-linux-amd64/arm64.tar.gz` 解包后的 `kk` 摘要与 `lib/kk-binaries.sha256` 一致，`tools/kk-fetch.sh --check` 通过。
- 安装后文件大小与摘要：`tools/amd64/kk` 119,697,607 B / `5e614f43…`；`tools/arm64/kk` 113,460,678 B / `cc764c11…`。
- 模板差异用 `git diff v4.0.9 v4.0.10 -- builtin/core` 逐文件核对；合入后与本机 `kk-project` 再做 `cmp` 校验。
- 合入的模板函数在 v4.0.9 与 v4.0.10 中均存在，未引入仅 4.0.10 才有的模板函数。
- Linux 二进制无法在 macOS 本机执行 `kk version`；`choose_kk` 会在首次安装时执行该检查并与 `KK_VERSION` 比对，届时可确认运行版本。
- 本地无法完成实机部署验证（需要 Linux 控制端与节点）；现场验收仍是接收方责任。
