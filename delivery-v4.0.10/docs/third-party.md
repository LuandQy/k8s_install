# 随附组件与来源

本页帮助接收方识别介质中的第三方组件。版本以当前交付介质及配置清单为准；不要仅修改版本字符串或替换单个二进制。完整性用根 SHA256SUMS 核对，内层制品另有 artifact/SHA256SUMS。

| 组件 | 随包位置及版本依据 | 上游项目 |
| --- | --- | --- |
| KubeKey | 仅 tools/{amd64,arm64}/kk 两架构 kk；随包 v4.0.10，v4.0.9 摘要保留以便回退（见 lib/kk-binaries.sha256） | [KubeKey](https://github.com/kubesphere/kubekey) |
| jq | tools/amd64/jq、tools/arm64/jq；1.8.1 | [jq](https://github.com/jqlang/jq) |
| ORAS | artifact/tools/ 两架构归档；1.3.0 | [ORAS](https://github.com/oras-project/oras) |
| nerdctl | artifact/tools/ 两架构归档；2.2.1 | [nerdctl](https://github.com/containerd/nerdctl) |
| 控制端 bootstrap | Ubuntu 24.04 noble amd64 本地软件包；精确版本见[包目录](bootstrap-packages.json)及归档内 Packages | [Ubuntu](https://ubuntu.com/) |
| Kubernetes、etcd、Harbor、CRI、CNI、存储组件与镜像 | [artifact/manifests.yaml](../artifact/manifests.yaml)列出介质候选版本；实际版本选择还受 kk-project/roles/defaults/vars 中对应 Kubernetes 版本配置约束 | 各组件发行项目及镜像仓库，以清单记录为准 |

Kubernetes 候选版本为 v1.36.4、v1.35.8、v1.34.11、v1.33.13，Harbor 为 v2.10.2。KubeKey 随包 v4.0.10，官方二进制摘要与模板合并记录见 [KubeKey v4.0.10 评估](kubekey-4.0.10.md)；回退须重新验收。清单中存在某版本、系统依赖类型或镜像，不等于该组合已在接收环境部署验收；选择范围见[部署检查表](deployment-checklist.md)。

第三方组件保持原介质字节。ORAS 两个归档含同一 LICENSE，本包额外提供便于离线查阅的[原许可文本](../licenses/ORAS-1.3.0-LICENSE)。其它组件的许可、版权说明及可能随软件提供的源码材料，以对应版本的原发行物、镜像和系统软件包为准；Ubuntu 软件包安装后的版权信息通常位于其 `/usr/share/doc/` 内容中。顶层部署脚本的交付不重新许可这些第三方组件。

本页是组件索引，不是完整 SBOM，也不表示已完成所有嵌套镜像、软件包或分发义务的独立审计。需要完整合规材料的接收流程，应按精确介质摘要向供方索取对应材料，不能从“部署检查通过”推导该结论。联网重制内层介质的 `package.sh` 属于供方制包工具，不是接收方离线部署步骤。
