# 后续优化点（未实施，按优先级）

本页记录本副本已经识别、但未在本次改动中实施的事项。它们不改变当前交付的验收边界，只作为下一轮开发输入。

| 优先级 | 事项 | 现状与影响 | 建议做法 |
| --- | --- | --- | --- |
| P1 | 制品与 v4.0.10 的现场复核（已决定不重制） | 制品由 v4.0.9 导出、引擎为 v4.0.10；#3290 的 ISO 修复只在新制 ISO 中生效 | 首轮 deps/images-import 验收重点观察缺包与清单差异；确有问题再按 [KubeKey v4.0.10 评估](kubekey-4.0.10.md) 用 v4.0.10 重制 |
| P0 | 把密码与日志纳入凭据管理（已完成一期收敛） | 已对 Web 提交的内存密码在 `JobLog` 中实施精确 `[REDACTED]` 掩码，并将 `4 MiB` 硬截断升级为 `1 MiB 头 + 3 MiB 尾` 双段保留 | 后续可继续接入系统密钥环与跨任务日志归档审计 |
| P1 | Master/Etcd 奇数高可用与 K8s 节点 `nerdctl` 预装（已完成） | Master 与 Etcd 已强制同机一一绑定且数量须为 `1/3/5…` 正奇数（≥3 强制 VIP）；`INSTALL_NERDCTL=true` 默认在前置阶段为全部 K8s 节点安装 `nerdctl` 与 `/etc/nerdctl/nerdctl.toml` | 保持奇数法定人数与同机约束 |
| P1 | Web 执行器维护与预探测增强（已部分完成） | 页面现已支持提交前只读节点连通性与架构/OS 预探测（`/api/execution/probe-nodes`）、零远端变更 `access` 失败原地重试、以及已有受管集群状态看板与可视化 Worker 扩容（`/api/execution/clusters`、`/api/execution/expand-workers`）；`resume/reset/redeploy` 仍保持由 CLI 执行 | 后续可按需补齐多步交互确认并完成实机回归后接入其余维护入口 |
| P1 | HA Harbor 的 Web 执行 | 页面已开放配置/校验/只读计划，提交执行明确拒绝；尚未实机验证 VIP、token 共享与 VRID | 先用 CLI 完成 HA 实机验收，再把 `ha-harbor` 纳入执行计划与确认模板 |
| P1 | Web 首装占用按集群名而非目标节点 | 任务 `failed`/`stopped` 后可换集群名对同一批节点再次首装；当前仅靠文档提醒 | 把占用绑定到节点身份集合，或在存在非 `succeeded` 任务时要求管理员显式解除 |
| P2 | 远程 SSH 会话 Web 访问引导（已完成） | `deploy.sh web` 在保持 `127.0.0.1` 回环绑定安全前提下，检测到 `SSH_CONNECTION` 等环境变量时自动打印 `ssh -N -L` 本机端口转发命令 | 保持禁止默认绑定 `0.0.0.0` |
| P2 | 日志结构化与级别下沉 | 前端按行分类 Info/Warn/Error/Debug；CLI 用文本前缀 | CLI 输出 JSON Lines（level/stage/node/ts），执行器按级别落盘，前端只做展示 |
| P2 | 配置差异视图增强 | 已展示“相对默认值”的字段差异 | 增加仅看变更、按分组筛选、复制差异清单到工单 |
| P2 | 制品清单断言前移 | `verify_artifact` 已 fail-closed | 在 `render`/`plan` 阶段也检查版本模板可解析，提前暴露“换版本后模板不匹配” |
| P2 | 测试进入 CI | `tests/` 目前只在本机跑 | Linux + Bash 5 + Python 3.8/3.12 矩阵；补 CLI 集成（render/plan/config-check/artifact verify）与 HTTP 契约 |
| P2 | 扩容与重建后的 workflow 快照与台账同步（已完成） | `scale-worker` 与 `redeploy` 完成后通过 `lib/post-verify.sh` 自动同步 `.workflow` 快照并刷新节点镜像验收、集群功能验收与台账 | 持续覆盖多节点实机回归 |
| P2 | Web 的 `HARBOR_KEY` 私钥权限强制（已完成） | `ExecutionService._inputs` 已与 SSH 私钥一致强制要求 `HARBOR_KEY` 为 `0600`/`0400` 权限，拒绝组或其他用户可读 | 保持执行器输入最小权限基线 |
| P2 | Web `binding.json` 损坏时幂等查询容错（已完成） | 已将 `binding` 同步落盘到 `job.json`，`binding.json` 缺失或损坏时可回退比对并准确返回状态 | 保持不可靠记录时保守拒绝对重放冲突的修改 |
| P3 | Harbor 导入后验证超时为 0 | HA 复制/同步较慢时一次失败即终止，没有重试窗口 | 允许受控重试与可配置超时，结果写入证据 |
| P3 | 旧版 resume 的 `images_ready` 可能缺少镜像证据 | 仅旧版路径可达；`COMPONENTS=all` 会直接置 true | 由镜像验收记录推导，或补充证据后才置位 |
| P3 | NFS 前置检查未在 deps 阶段执行 | `nfs-server.sh` 到 `services-init` 才检查 `exportfs` | 前移到 `deps`/`prepare`，提前暴露缺包 |
| P3 | 跟踪上游新版本 | 版本表手工维护 | 定时抓取 Release 与 `builtin/core` 差异，生成“模板侧可合并/构建侧需重制”的报告 |
| P3 | 删除或真正实现未使用字段 | `rise.external_cert/external_key` 无消费者；BYO 根 CA 已由 `PKI_ROOT_*` 独立支持 | 从模板中移除这两个字段，或明确改为 Harbor 叶子证书入口 |

## 原则

- 任何改动都必须保持三条边界：状态/回执指纹不可绕过；阶段失败不发布成功；日志与凭据按敏感材料保管。
- 新增 Web 能力时，仍复用 CLI 的最终校验与执行路径，不在前端复制规则。
