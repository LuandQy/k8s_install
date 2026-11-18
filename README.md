# Kubernetes + Harbor 离线工程化交付套件 (KubeKey v4.0.10)

面向内网与严格离线环境的 Kubernetes + Harbor 自动化部署、验收与台账交付仓库。底层执行引擎基于定制版 KubeKey `v4.0.10`，上层提供 **CLI 交互/静默入口** 与 **特权分离的本机 Web 三步向导**，内置 13 阶段有向证据链编排、节点实机 CRI/Pod 闭环验收与零外部依赖的 9 表 Excel 台账导出。

---

## 核心能力

- **双入口共享同一状态机**：CLI（`./deploy.sh cli`）与本机 Web（普通用户 `server.py` + `root` Unix Socket `executor.py`，基于内核 `SO_PEERCRED` 鉴权）共用 `lib/workflow.sh` 与同一套防篡改阶段回执。
- **高可用拓扑防脑裂约束**：
  - `Master` 与 `Etcd` 强制同机一一对应，节点数量必须为 **`1 / 3 / 5 / 7...` 正奇数**，从配置层拦截偶数法定人数退化与脑裂隐患。
  - 多控制平面（`>= 3`）支持三种高可用入口：`kube-vip`（控制平面漂移 VIP）、`haproxy`（纯 Worker 节点内置本地 HAProxy Static Pod 代理全部控制平面，免申请 VIP，适配公有云/跨三层子网/虚拟化 NAT）及 `external`（外部负载均衡）。
- **K8s 节点前置预装 `nerdctl`**：默认启用 `INSTALL_NERDCTL=true`（Web 首屏默认勾选），在节点前置准备阶段自动按 `amd64` / `arm64` 架构校验并解压 `nerdctl`（`v2.2.1`）至 `/usr/local/bin/nerdctl`，生成 `/etc/nerdctl/nerdctl.toml`（默认绑定 `namespace = "k8s.io"`、`cgroup_manager = "cgroupfs"` 与容器证书目录）。
- **全生命周期实机验收与台账同步**：
  - 首装、`redeploy` 重建与 `scale-worker` 扩容均同步 `.workflow` 指纹快照，自动串联逐节点 CRI 实拉摘要核对、测试 Pod 跨节点网络/DNS/TLS/PVC 读写验收与内核块设备 I/O 错误监测，直出 `.xlsx` / `.json` / `.html` / `.csv` 交付台账。
- **安全与可观测性保护**：
  - Web 导入 `.env` 采用有限状态机字面量解析，绝不调用 Shell `source` / `eval`；
  - 停止指令仅在阶段边界生效（`DELIVERY_STOP_FILE`），不强杀分区或 `kubeadm` 进程；
  - Web 任务日志自动对本次提交的内存密码执行精确 `[REDACTED]` 掩码，并在超出 `4 MiB` 时保留 **头部 `1 MiB` + 最新尾部 `3 MiB`**。

---

## 仓库目录结构

| 路径 | 说明 |
| --- | --- |
| [`delivery-v4.0.10/`](delivery-v4.0.10/) | 正式离线交付包主体目录（含 `deploy.sh`、`lib/`、`web/`、`node_scripts/`、`kk-project/`、`configs/`、`examples/`、`docs/`、`tests/`） |
| [`delivery-v4.0.10/README.md`](delivery-v4.0.10/README.md) | 交付包接收校验、CLI/Web 快速启动与 15 份运维/架构手册总索引 |
| [`release.sh`](release.sh) | 发布前防呆流水线：清理字节码、Shell 语法检查、运行 Node + Python 回归单测、刷新并核验 `SOURCE_SHA256SUMS` 与 `SHA256SUMS` |
| [`manage_lima_cluster.sh`](manage_lima_cluster.sh) | macOS (Apple Silicon / Intel) 本地一键拉起/销毁 3 节点 Lima 虚拟化验证集群 |
| [`simulate_web_deployment.py`](simulate_web_deployment.py) | Web 工作台分阶段（`prepare -> harbor -> k8s`）端到端自动化回归驱动 |
| [`verify_ledger.py`](verify_ledger.py) | 交付台账 Excel 9 张工作表结构与验收字段断言脚本 |
| [`docs/superpowers/`](docs/superpowers/) | 架构演进设计规格与实施计划记录（独立于 `delivery-v4.0.10/`，不进入对外交付清单） |

---

## 大体积离线制品与二进制制作（基于 KubeKey v4）

本项目基于上游 [kubesphere/kubekey](https://github.com/kubesphere/kubekey)（`v4.0.10`）构建。为保持 Git 仓库轻量，`.gitignore` 已排除多 GiB 离线归档与二进制工具。克隆本仓库后，如需构建完整离线交付目录或执行实机部署，完整分步教程（含架构/版本裁剪、国内源注意事项、使用 `hack/gen-repository-iso` 自制未托管系统 ISO、制作 Ubuntu/Kylin `bootstrap` 包）请查阅 **[基于 KubeKey v4 的全量离线包制作指南](delivery-v4.0.10/docs/offline-package-build.md)**。

### 核心离线文件清单

| 目标路径 | 用途 | 获取或生成方式 |
| --- | --- | --- |
| `delivery-v4.0.10/tools/{amd64,arm64}/kk` | KubeKey `v4.0.10` 执行与导出引擎 | 运行 `./delivery-v4.0.10/tools/kk-fetch.sh --version v4.0.10 --apply`（自动核对 `lib/kk-binaries.sha256`） |
| `delivery-v4.0.10/tools/{amd64,arm64}/jq` | 控制端内置静态 `jq`（`1.8.1`） | 下载官方 `jq-linux-{amd64,arm64}` 静态二进制放入对应目录并赋予 `0755` 权限 |
| `delivery-v4.0.10/artifact/kubekey-artifact.tgz` 与 `manifests.yaml` | K8s / Harbor / Calico / `kube-vip` / `haproxy` / OS ISO 内层制品包 | 在联网 Linux 制包机运行 `PACKAGE_WORK_DIR=/data/kubekey-package bash package.sh`（底层调用 `kk artifact export`） |
| `delivery-v4.0.10/artifact/tools/{amd64,arm64}/{nerdctl,oras}*.tar.gz` | 节点预装 `nerdctl`（`v2.2.1`）与镜像推送工具 `oras`（`v1.3.0`） | `kk artifact export` 自动拉取至工作目录 `artifact/tools/`（手工更新后需运行 `./tools/artifact-refresh.sh`） |
| `delivery-v4.0.10/bootstrap/bootstrap-*.tar.gz` | 控制端与节点离线系统引导包（含同名 `.sha256`） | 在目标发行版干净环境中通过 `apt-get download` / `dnf download` 制作本地源归档 |

### 联网 Linux 制包机一键制作主流程

```bash
# 1. 拉取并校验双架构 KubeKey v4.0.10 与静态 jq
cd delivery-v4.0.10
./tools/kk-fetch.sh --version v4.0.10 --apply
curl -fL -o tools/amd64/jq https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-amd64
curl -fL -o tools/arm64/jq https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-arm64
chmod 0755 tools/amd64/jq tools/arm64/jq

# 2. 按 package-config.yaml 导出 kubekey-artifact.tgz、manifests.yaml、nerdctl/oras 及 artifact/SHA256SUMS
#    注意：务必使用独立 PACKAGE_WORK_DIR，避免导出过程清空原 artifact/ 或混入临时下载缓存
PACKAGE_WORK_DIR=/data/kubekey-package bash package.sh
rm -rf artifact && cp -a /data/kubekey-package/artifact artifact

# 3. 运行只读离线依赖与 OCI 镜像闭包审计（确认退出码为 0）
python3 lib/offline-audit.py --root . --output /tmp/offline-audit-v1.36.4 --kubernetes v1.36.4 --arch amd64

# 4. 回到仓库根目录执行单测回归、刷新防篡改清单并打包最终发行归档
cd ..
bash release.sh --pack delivery-v4.0.10-$(date +%Y%m%d).tar.gz
```

> 仅在本地运行配置工作台预览、导入导出 `.env` 或执行单元测试时，无需下载上述多 GiB 离线制品。

---

## 快速使用

### 1. 本机启动 Web 配置工作台（普通用户，免 root）

```bash
cd delivery-v4.0.10
bash deploy.sh web --data-dir /tmp/rise-config-drafts --port 8765
```

在浏览器打开终端输出的 `http://127.0.0.1:8765/#token=...` 临时链接即可填写拓扑、切换 `kube-vip` / `haproxy` / `external` 入口、预览数据盘软链接并导出 `cluster-vars.env`。如需在页面直接提交后台部署，按 [`delivery-v4.0.10/docs/web-deployment.md`](delivery-v4.0.10/docs/web-deployment.md) 启动 `root` 执行器并传入 `--executor-socket`。

### 2. Linux 控制端 CLI 部署

```bash
cd delivery-v4.0.10
# 交互式菜单与配置向导
sudo ./deploy.sh cli

# 使用已审阅配置非交互执行全流程
sudo ./deploy.sh cli --auto-default --env /etc/rise/site.env -y
```

### 3. 开发回归与清单刷新

修改任何脚本、前端逻辑或文档后，在仓库根目录执行：

```bash
# 运行语法检查、前端与 Python 单元测试，并刷新交付包 SHA256 清单
bash release.sh

# 如需同时打包生成外层 tar.gz 与 .sha256
bash release.sh --pack delivery-v4.0.10-$(date +%Y%m%d).tar.gz
```

---

## 详细文档导航

完整部署前置、拓扑规划、分步接管与故障恢复请查阅 [`delivery-v4.0.10/docs/`](delivery-v4.0.10/docs/) 下的专题手册：

- [基于 KubeKey v4 的全量离线包制作指南](delivery-v4.0.10/docs/offline-package-build.md)
- [架构与执行链路](delivery-v4.0.10/docs/architecture.md)
- [部署前置条件与验收边界](delivery-v4.0.10/docs/deployment-checklist.md)
- [默认值、连接方式与快速上手](delivery-v4.0.10/docs/quick-start.md)
- [交互式 CLI 部署指南](delivery-v4.0.10/docs/deploy-guide.md)
- [Web 配置工作台说明](delivery-v4.0.10/docs/web-config.md)
- [Web 一键部署指南](delivery-v4.0.10/docs/web-deployment.md)
- [多节点与外部 Harbor 部署说明](delivery-v4.0.10/docs/multinode-deployment.md)
- [维护、扩容、重建与故障处理手册](delivery-v4.0.10/docs/operations.md)
- [高级分步参考](delivery-v4.0.10/docs/staged-install.md)
