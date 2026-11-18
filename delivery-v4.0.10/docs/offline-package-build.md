# 基于 KubeKey v4 的全量离线包制作指南

本项目的离线交付能力基于上游开源项目 [kubesphere/kubekey](https://github.com/kubesphere/kubekey)（当前基线版本 `v4.0.10`）构建。为保持 Git 代码仓库轻量，`.gitignore` 默认排除了多 GiB 的二进制、容器镜像归档与操作系统软件源 ISO。克隆本仓库后，按本文步骤即可在一台联网 Linux 机器上从零制作出可通过防篡改校验与离线闭包审计的完整交付介质。

## 1. 离线交付介质分层结构

标准上游 KubeKey v4 通过 `kk artifact export` 产出内层制品包 `kubekey-artifact.tgz` 与 `manifests.yaml`。本项目在其外围增加了控制端静态工具、K8s 节点前置 `nerdctl` 离线包、裸机离线引导仓库（`bootstrap/`）以及多层 SHA256 防篡改清单：

```text
delivery-v4.0.10/
├── tools/                                   # [第 1 层] 控制端内置可执行工具
│   ├── amd64/{kk,jq}                        # x86_64 架构 KubeKey v4.0.10 与静态 jq
│   └── arm64/{kk,jq}                        # aarch64 架构 KubeKey v4.0.10 与静态 jq
├── artifact/                                # [第 2 层] KubeKey 核心离线制品与伴随工具
│   ├── kubekey-artifact.tgz                 # K8s/etcd/CRI/CNI/Harbor 二进制、Helm Chart、OCI 镜像与 OS ISO
│   ├── manifests.yaml                       # 随 kubekey-artifact.tgz 导出的组件与镜像清单
│   ├── SHA256SUMS                           # 覆盖 artifact/ 下全部文件的强制校验清单
│   └── tools/
│       ├── amd64/
│       │   ├── nerdctl-2.2.1-linux-amd64.tar.gz
│       │   └── oras_1.3.0_linux_amd64.tar.gz
│       └── arm64/
│           ├── nerdctl-2.2.1-linux-arm64.tar.gz
│           └── oras_1.3.0_linux_arm64.tar.gz
├── bootstrap/                               # [第 3 层] 控制端与节点离线系统引导包（可选但推荐）
│   ├── bootstrap-noble-amd64.tar.gz         # Ubuntu 24.04 离线 apt 包仓库（jq/sshpass/openssh-client 等）
│   └── bootstrap-noble-amd64.tar.gz.sha256
├── SOURCE_SHA256SUMS                        # [第 4 层] 源码、模板与文档完整性清单
└── SHA256SUMS                               # [第 4 层] 整包全文件完整性清单
```

各层制品与上游 KubeKey v4 机制的对应关系如下：

| 目录或文件 | 部署阶段用途 | 制作来源 |
| --- | --- | --- |
| `tools/{amd64,arm64}/kk` | 控制端执行 Playbook 与导出离线包的核心引擎 | `./tools/kk-fetch.sh` 拉取官方 KubeKey Release 并核对 `lib/kk-binaries.sha256` |
| `tools/{amd64,arm64}/jq` | 控制端渲染配置与处理 JSON 状态（免依赖系统 `jq`） | 官方 `jqlang/jq` 静态编译二进制（`1.8.1`） |
| `artifact/kubekey-artifact.tgz` | 提供 K8s 组件、Harbor 离线安装包、多架构 OCI 镜像（含 `kube-vip` 与 `haproxy`）及 `repository/*.iso` | `package.sh` 调用 `kk artifact export` 根据 `package-config.yaml` 导出 |
| `artifact/tools/*/{nerdctl,oras}*.tar.gz` | `oras` 用于向 Harbor 推送 OCI 镜像；`nerdctl` 在节点初始化阶段预装至全部 K8s 节点 `/usr/local/bin/nerdctl` | `kk artifact export` 执行 `download/package` 角色时自动下载并复制（也可手工放入） |
| `bootstrap/bootstrap-*.tar.gz` | 最小化离线控制端安装 `jq`/`sshpass`/`openssh-client`，或节点 `DEPS_MODE=bootstrap` 装包 | 在对应发行版干净容器或虚机中通过 `apt-get download` / `dnf download` 打包 |

## 2. 制包机器环境要求

1. **操作系统**：联网的 **Linux** 主机（`x86_64` 或 `aarch64`）。`package.sh` 会检查 `uname -s = Linux`，因为 `tools/<arch>/kk` 是 Linux ELF 二进制；若日常在 macOS 开发，可通过仓库根目录的 `./manage_lima_cluster.sh`、OrbStack 或任意 Linux 虚拟机执行导出。
2. **磁盘空间**：
   - 默认全量配置（`amd64` + `arm64` 双架构、4 个 K8s 版本、3 套操作系统 ISO）峰值需要约 **25 GiB 至 35 GiB** 可用空间（含 `kubekey/` 原始下载缓存、打包暂存目录与约 `6.6 GiB` 的最终归档）。
   - 单架构（如仅 `amd64`）+ 单个 K8s 版本 + 单一 OS ISO 约需 **8 GiB 至 10 GiB** 可用空间。
3. **基础命令**：`bash`、`curl`、`tar`、`sha256sum`、`python3`。若在 `package-config.yaml` 中额外自定义了 `spec.download.charts`，制包机 `PATH` 中还需安装 `helm` CLI。
4. **网络访问与国内镜像源注意事项（重要）**：
   - 默认情况下，`package-config.yaml` 中的 `spec.zone` 为空字符串 `""`，KubeKey 会直接从 `dl.k8s.io`、`registry.k8s.io`、`docker.io`、`quay.io` 与 `github.com` 拉取上游原版构件，建议在制包机通过 `export HTTPS_PROXY=http://<proxy>:<port>` 保障稳定拉取。
   - 上游 KubeKey 支持设置 `spec.zone: "cn"` 切换至青云对象存储镜像（`kubekey.pek3b.qingstor.com`）加速二进制、Helm Chart、OS ISO 与 `oras`/`nerdctl` 下载。**但在本项目中若启用 `spec.zone: "cn"`，必须在 `package-config.yaml` 的 `spec.download.images` 下显式补充 `registry: ""`**：否则 KubeKey 默认模板会将 `manifests.yaml` 与归档内的镜像前缀改写为 `hub.kubesphere.com.cn/...`，导致后续离线部署时与 `lib/images.sh` 校验的上游标准镜像名（`registry.k8s.io/...`、`docker.io/...`、`quay.io/...`）不一致。

## 3. 步骤一：准备控制端二进制 (`tools/{amd64,arm64}/{kk,jq}`)

### 3.1 拉取并核验 KubeKey `v4.0.10` 二进制

仓库内置供应商脚本 `tools/kk-fetch.sh`，自动从 GitHub Releases 下载 `amd64` 与 `arm64` 双架构官方归档，对比 `lib/kk-binaries.sha256` 中的可信摘要后写入 `tools/{amd64,arm64}/kk`：

```bash
cd delivery-v4.0.10

# 下载官方 v4.0.10 双架构 kk，核对 SHA256 后安装至 tools/{amd64,arm64}/kk
./tools/kk-fetch.sh --version v4.0.10 --apply

# 离线核对已就位的二进制摘要
./tools/kk-fetch.sh --version v4.0.10 --check
```

补充参考（上游 KubeKey 官方下载或源码自编译方式）：

- 若需测试新的官方 `v4.0.x` 补丁版本，可执行 `./tools/kk-fetch.sh --version v4.0.x --record --apply` 将核实后的新版本摘要追加记录到 `lib/kk-binaries.sha256`。
- 若基于 [kubesphere/kubekey](https://github.com/kubesphere/kubekey) 源码定制编译（`git checkout v4.0.10 && make build`），将产物放入 `tools/amd64/kk` 与 `tools/arm64/kk` 后，需同步更新 `lib/kk-binaries.sha256` 中对应行的 SHA256 值。

### 3.2 准备双架构静态 `jq`

控制端脚本优先调用 `tools/<arch>/jq`（版本 `1.8.1`），避免离线控制端缺少系统级 `jq`：

```bash
cd delivery-v4.0.10
install -d -m 0755 tools/amd64 tools/arm64

curl -fL --retry 3 -o tools/amd64/jq \
  https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-amd64
curl -fL --retry 3 -o tools/arm64/jq \
  https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-arm64

chmod 0755 tools/amd64/jq tools/arm64/jq
```

## 4. 步骤二：定制离线制品清单 (`package-config.yaml`)

在上游 KubeKey v4 中，离线导出配置遵循 `apiVersion: kubekey.kubesphere.io/v1`（`kind: Config`）规范，可通过 `./tools/amd64/kk create config` 查看默认字段。本项目已在 `delivery-v4.0.10/package-config.yaml` 中固化了与 `configs/v*.yaml` 及 `kk-project/roles/defaults/vars/v*.yaml` 严格对齐的生产交付清单。

### 4.1 按现场需求裁剪架构、版本或操作系统（减小归档体积）

编辑 `delivery-v4.0.10/package-config.yaml` 可按目标环境裁剪范围：

1. **架构范围（`spec.download.arch`）**：默认同时导出 `amd64` 与 `arm64`。纯 `x86_64` 现场可仅保留 `amd64`，归档体积可缩减约一半。
2. **Kubernetes 与配套组件版本**：
   - `spec.download.kubernetes.kube_version` 默认包含 `v1.36.4`、`v1.35.8`、`v1.34.11`、`v1.33.13`。
   - 若仅保留部分版本（如仅 `v1.36.4`），请确保 `etcd`、`cri`（`containerd_version`、`runc_version`、`crictl_version`、`docker_version`）、`cni`（`calico_version`）中保留了 `kk-project/roles/defaults/vars/v1.36.yaml` 所引用的全部对应版本号，同时将不需要对外展示的 `configs/v1.33.13.yaml` 等模板移出 `configs/` 目录。
3. **内置高可用负载均衡镜像说明**：
   - KubeKey v4 的 `roles/defaults/templates/manifests.yaml` 会自动将 `docker.io/plndr/kube-vip:v0.7.2` 与 `docker.io/library/haproxy:2.9.6-alpine` 加入导出清单，因此无论是 `kube-vip` 漂移 VIP 模式还是 `haproxy` Worker 本地静态 Pod 负载均衡模式，均无需手工补写镜像即可开箱离线使用。
4. **追加额外业务或运维镜像（`spec.image_manifests`）**：
   - 如需在 `kubekey-artifact.tgz` 中顺带打包额外的容器镜像，在 `package-config.yaml` 的 `spec:` 下添加顶层字段 `image_manifests`：

```yaml
spec:
  image_manifests:
  - docker.io/library/nginx:1.27-alpine
  - quay.io/prometheus/node-exporter:v1.8.2
```

### 4.2 操作系统依赖 ISO 配置与自制方法

`package-config.yaml` 的 `spec.download.iso` 控制打入 `kubekey-artifact.tgz` 内 `repository/<iso>-<arch>.iso` 的系统软件源镜像：

- **直接引用 KubeKey 官方预制 ISO**：
  上游 KubeKey 在 GitHub Releases 的 [`iso-latest`](https://github.com/kubesphere/kubekey/releases/tag/iso-latest) 标签下托管了常用发行版 ISO（如 `ubuntu-24.04-debs`、`ubuntu-22.04-debs`、`kylin-v10SP3-2403-rpms`、`debian-11-debs`、`almalinux-9.0-rpms` 等，完整候选见 `kk-project/roles/defaults/defaults/main/10-download.yaml`）。列入 `spec.download.iso` 后，`kk artifact export` 会按 `arch` 自动下载。
- **基于上游 `hack/gen-repository-iso` 自制未托管发行版 ISO**：
  当目标内网系统（例如特定小版本的 Rocky Linux、openEuler 或定制版麒麟）不在 KubeKey 官方 `iso-latest` 列表中时，使用上游 KubeKey 仓库的官方制作工具生成：
  1. 在安装有 Docker 的联网 Linux 机器上克隆上游仓库并进入制作目录：
     ```bash
     git clone --depth 1 --branch v4.0.10 https://github.com/kubesphere/kubekey.git
     cd kubekey/hack/gen-repository-iso
     ```
  2. 参考该目录下的说明与发行版配置，在目标系统容器内解析并下载离线依赖包（至少覆盖 `socat`、`conntrack`、`ipset`、`ebtables`、`ipvsadm`、`iptables`、`nfs-common`/`nfs-utils`、`chrony`、`tar`、`curl`、`openssl`），生成命名形如 `<custom-os>-<arch>.iso` 的 ISO 文件。
  3. **预置到打包缓存目录**：KubeKey 的 `roles/download/tasks/iso.yaml` 在下载前会先判断 `$PACKAGE_WORK_DIR/kubekey/repository/<iso>-<arch>.iso` 是否已存在；若文件已存在则跳过远程下载并直接打入制品包：
     ```bash
     mkdir -p /data/kubekey-package/kubekey/repository
     cp /path/to/<custom-os>-amd64.iso /data/kubekey-package/kubekey/repository/
     ```
  4. 在 `package-config.yaml` 的 `spec.download.iso` 中填入 `<custom-os>`，再执行下一步导出。

## 5. 步骤三：导出 `artifact/` 内层制品与伴随工具

### 5.1 使用独立 `PACKAGE_WORK_DIR` 运行 `package.sh`

强烈建议通过环境变量 `PACKAGE_WORK_DIR` 指定交付目录之外的独立工作目录（例如 `/data/kubekey-package`），原因有两点：

1. KubeKey 的 `download/package` 角色在封装开始时会执行 `rm -rf {{ .artifact_dir }} && mkdir -p {{ .artifact_dir }}` 清空目标 `artifact/` 目录；
2. 导出过程会在 `$PACKAGE_WORK_DIR/kubekey/` 缓存数十 GiB 解包构件，并在 `$PACKAGE_WORK_DIR/tools/<arch>/` 缓存下载的 `oras` 与 `nerdctl` 压缩包，使用外部工作目录可避免污染 `delivery-v4.0.10/tools/`。

在联网 Linux 制包机上执行：

```bash
cd /path/to/delivery-v4.0.10

# 调用 tools/<arch>/kk artifact export --workdir /data/kubekey-package -c package-config.yaml
# 并在导出完成后自动计算生成 /data/kubekey-package/artifact/SHA256SUMS
PACKAGE_WORK_DIR=/data/kubekey-package bash package.sh
```

执行成功后，KubeKey 与 `package.sh` 会在 `/data/kubekey-package/artifact/` 下完整产出以下 6 个文件（其中 `nerdctl` 与 `oras` 由 KubeKey 的 `download.tools` 任务自动拉取并复制到 `artifact/tools/<arch>/`）：

- `kubekey-artifact.tgz`
- `manifests.yaml`
- `tools/amd64/nerdctl-2.2.1-linux-amd64.tar.gz`
- `tools/amd64/oras_1.3.0_linux_amd64.tar.gz`
- `tools/arm64/nerdctl-2.2.1-linux-arm64.tar.gz`
- `tools/arm64/oras_1.3.0_linux_arm64.tar.gz`
- `SHA256SUMS`

确认无误后，将导出的 `artifact/` 目录同步回交付包目录：

```bash
rm -rf /path/to/delivery-v4.0.10/artifact
cp -a /data/kubekey-package/artifact /path/to/delivery-v4.0.10/artifact
```

### 5.2 单独补齐或更新 `nerdctl` / `oras` 工具包

若你复用了既有的 `kubekey-artifact.tgz`（或导出时仅指定了单架构，事后需手工补齐另一架构的伴随工具），可直接下载对应版本的官方归档放入 `artifact/tools/{amd64,arm64}/`，随后运行 `tools/artifact-refresh.sh` 重算摘要：

```bash
cd /path/to/delivery-v4.0.10
install -d -m 0755 artifact/tools/amd64 artifact/tools/arm64

# nerdctl v2.2.1（节点前置脚本 node_scripts/nerdctl.sh 默认预装至全部 K8s 节点）
curl -fL --retry 3 -o artifact/tools/amd64/nerdctl-2.2.1-linux-amd64.tar.gz \
  https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-amd64.tar.gz
curl -fL --retry 3 -o artifact/tools/arm64/nerdctl-2.2.1-linux-arm64.tar.gz \
  https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-arm64.tar.gz

# ORAS v1.3.0（控制端向 Harbor 导入离线 OCI 镜像时使用）
curl -fL --retry 3 -o artifact/tools/amd64/oras_1.3.0_linux_amd64.tar.gz \
  https://github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_amd64.tar.gz
curl -fL --retry 3 -o artifact/tools/arm64/oras_1.3.0_linux_arm64.tar.gz \
  https://github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_arm64.tar.gz

# 强制刷新 artifact/SHA256SUMS（lib/artifact.sh 在部署前会严格比对该清单）
./tools/artifact-refresh.sh
```

## 6. 步骤四：制作 `bootstrap/` 控制端与节点离线引导包

当离线现场的最小化安装系统缺少 `jq`、`util-linux`、`openssh-client` 或密码模式所需的 `sshpass` 时，管理员会执行 `sudo ./deploy.sh bootstrap [--with-sshpass]` 从 `bootstrap/` 本地安装；若节点采用 `DEPS_MODE=bootstrap`，也会自动匹配同一命名规则的归档。

归档命名契约为 `bootstrap-<distro>-<arch>.tar.gz` 及同名 `.sha256`：

- `distro`：Ubuntu 使用发行版代号（`noble` 对应 24.04，`jammy` 对应 22.04），Kylin V10 统一使用 `ky10`；
- `arch`：`amd64`、`arm64`（Kylin ARM 环境兼容 `aarch64`）。

### 6.1 制作 Ubuntu (`noble` / `jammy`) `bootstrap` 包

在与目标系统同版本、同架构的干净 Ubuntu 容器中执行：

```bash
docker run --rm -v "$PWD/bootstrap:/out" ubuntu:24.04 bash -euxc '
  apt-get update
  apt-get install -y dpkg-dev ca-certificates
  mkdir -p /work/repo && cd /work/repo

  # 控制端引导核心包；若同时用于节点 DEPS_MODE=bootstrap，可追加：
  # socat conntrack ipset ebtables ipvsadm iptables nfs-common nfs-kernel-server chrony
  PKGS="jq util-linux openssh-client sshpass"
  DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances $PKGS \
    | grep "^\w" | sort -u)
  apt-get download $DEPS

  dpkg-scanpackages . /dev/null > Packages
  gzip -9c Packages > Packages.gz
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf "%P\n" \
    | LC_ALL=C sort | xargs sha256sum > SHA256SUMS

  tar -czf /out/bootstrap-noble-amd64.tar.gz .
  cd /out && sha256sum bootstrap-noble-amd64.tar.gz > bootstrap-noble-amd64.tar.gz.sha256
'
```

### 6.2 制作 Kylin V10 (`ky10`) `bootstrap` 包

在与现场一致的 Kylin V10 联网主机或容器中执行：

```bash
mkdir -p /tmp/ky10-repo && cd /tmp/ky10-repo

dnf download --resolve --alldeps --destdir . \
  jq util-linux openssh-clients sshpass
createrepo_c .
find . -type f ! -name SHA256SUMS -print \
  | sed 's@^\./@@' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS

tar -czf /path/to/delivery-v4.0.10/bootstrap/bootstrap-ky10-aarch64.tar.gz .
(
  cd /path/to/delivery-v4.0.10/bootstrap
  sha256sum bootstrap-ky10-aarch64.tar.gz > bootstrap-ky10-aarch64.tar.gz.sha256
)
```

制作完成后，可用 `python3 lib/bootstrap-route.py --os-release /etc/os-release --machine $(uname -m) --bootstrap-dir bootstrap` 验证路由匹配，并将新增变体补充至 `docs/bootstrap-packages.json`。

## 7. 步骤五：离线闭包预检与最终发布包封装

全部制品就位后，切勿直接手工压缩目录，应依次运行只读离线审计与根目录发布流水线。

### 7.1 运行只读离线依赖与 OCI 镜像闭包审计

在 Linux 机器上针对每个交付的 Kubernetes 版本与架构运行 `lib/offline-audit.py`（只读零副作用，不挂载 ISO、不修改宿主机 `/var/lib/dpkg`、不联网）：

```bash
python3 delivery-v4.0.10/lib/offline-audit.py \
  --root delivery-v4.0.10 \
  --output /tmp/audit-v1.36.4-amd64 \
  --kubernetes v1.36.4 \
  --arch amd64
```

该脚本自动执行 7 项严苛检查并输出 `/tmp/audit-v1.36.4-amd64/report.json`：

1. 核对 `artifact/SHA256SUMS`、`bootstrap/*.sha256` 与 `lib/kk-binaries.sha256` 全部文件哈希；
2. 对照 `lib/artifact-requirements.sh` 核验目标 K8s 版本与架构所需的全部二进制、Helm Chart 与 `repository/*.iso` 均存在于 `kubekey-artifact.tgz`；
3. 免挂载解析 ISO 内的软件包索引并逐个校验 `.deb` / `.rpm` 文件摘要；
4. 解包并核对 `bootstrap-*.tar.gz` 内部 `SHA256SUMS`；
5. 使用隔离的 `APT_CONFIG` 模拟节点基础包、NFS 包与控制端引导包依赖求解；
6. 在空 `dpkg` 状态库上检验介质自身的依赖闭包完整性；
7. 遍历 `kubekey-artifact.tgz` 内 `images/` 下的全部 OCI Manifest，校验文件名哈希一致且引用的 Config / Layer Blob 零缺失。

退出码为 `0`（`blockers` 为空）方可进入最终封装。

### 7.2 刷新防篡改清单并生成对外发布归档

回到仓库根目录执行 `release.sh`，脚本会自动清理临时 `__pycache__`、执行全量 Shell 语法检查、运行前端 Node 与后端 Python 回归单测、重新计算并双向验证 `SOURCE_SHA256SUMS` 与 `SHA256SUMS`，最后按需打成带同名 `.sha256` 的最终发行包：

```bash
cd /path/to/repo-root

# 仅执行全套语法/单测回归并刷新 delivery-v4.0.10/{SOURCE_SHA256SUMS,SHA256SUMS}
bash release.sh

# 执行回归、刷新清单，并直接生成对外交付的外层归档与 .sha256
bash release.sh --pack delivery-v4.0.10-$(date +%Y%m%d).tar.gz
```

## 8. 常见问题速查

| 现象或报错信息 | 根因分析 | 处理方法 |
| --- | --- | --- |
| `错误: KubeKey 打包需要在 Linux 上执行` | 在 macOS 上直接执行了 `package.sh`，而 `tools/<arch>/kk` 为 Linux ELF 可执行文件 | 在联网 Linux 服务器或通过 `./manage_lima_cluster.sh` 拉起的 Linux 虚机内执行 `package.sh` |
| `离线依赖缺失: kube/v1.36.4/amd64/...` 或组件版本缺失 | `package-config.yaml` 导出的版本集合未覆盖 `kk-project/roles/defaults/vars/vX.Y.yaml` 声明的组件版本 | 核对对应 `vars/vX.Y.yaml` 中的版本号，补齐 `package-config.yaml` 后重新导出 |
| `工具缺失或摘要不匹配: .../nerdctl-2.2.1-linux-*.tar.gz` | 手工替换或新增了 `artifact/tools/` 下的文件，未同步刷新 `artifact/SHA256SUMS` | 在 `delivery-v4.0.10` 目录运行 `./tools/artifact-refresh.sh`，再运行根目录 `bash release.sh` |
| 离线导入镜像时提示找不到 `registry.k8s.io/...` 或 `docker.io/...` | 制包时设置了 `spec.zone: "cn"` 但未置空 `spec.download.images.registry`，导致归档内镜像被改写为 `hub.kubesphere.com.cn/...` | 在 `package-config.yaml` 中保持 `zone: ""`（配合代理），或在 `zone: "cn"` 时显式设置 `spec.download.images.registry: ""` 后重导 |
