# WSL 本地验证记录

适用交付：20261114-r5。WSL 仅用于本地验证，不作为生产控制端支持范围。以下结果来自一台 WSL2 Ubuntu 24.04 单节点（8 vCPU、15 GiB、根盘 ext4），验证时间 2026-11-15。

## 已跑通

- 源码入口：bootstrap、config-check、render、plan、access、prepare、deps、services-init、services-verify。
- Harbor：KubeKey 安装、harbor-projects、镜像导入、镜像验收；Harbor 健康检查 200。
- Kubernetes：KubeKey 安装当时 configs 默认版本 v1.36.4，节点 Ready，CoreDNS、Calico、LocalPV 就绪；node-images-verify 通过。
- 功能验收：直接使用修好的验收器，DNS、API TLS、Harbor TLS、Service、PVC 绑定/持久化/Pod 重建均通过。
- 回归：Linux Bash 5.2 + Python 3.12 下 31/31 测试通过；shell 语法检查与 Python 编译通过。

## WSL 环境差异（仅测试处理，不进入交付代码）

- Windows/WSL 网络模式下 Docker 发布端口（0.0.0.0）和主机 192.168.1.5:443 不可用；测试用 socat 显式绑定 192.168.1.5:18443 转发到 Harbor 容器 8443，并清掉 Docker 对 18443 的 DNAT。交付默认仍为 Harbor 443 或用户配置的 HARBOR_PORT；非 443 时由 image_registry.https_port 与客户端端口保持一致。
- nodelocaldns 在 WSL 下以主机网络转发 CoreDNS ClusterIP 超时；测试把上游改为 CoreDNS Pod IP。正常 Linux 主机不需要该处理。
- 验收脚本需要静态 busybox；离线 ISO 已包含 busybox-static，交付已把该包加入 deps 清单。

## 未完成/边界

- WSL 控制面在密集 Pod 重建后出现过瞬时 API 超时，功能检查已完成但一次 cleanup 未完成；这不作为生产稳定性结论。
- 未验证跨节点、HA Harbor、重启恢复、生产 NFS/存储性能；这些仍按部署边界文档另行验收。
