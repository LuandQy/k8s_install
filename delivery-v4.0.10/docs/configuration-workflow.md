# 从 Web、向导或模板衔接到 CLI

适用交付：20261114-r5。选择 CLI 部署时，`CONFIG` 是下文命令中明确指定的配置文件绝对路径，不是工具自动设置的环境变量。每个新终端都需要重新赋值；配置文件、Web 草稿名称和集群名称是三个不同概念。

使用 Web 直接部署时无需人工导出：管理员启用执行器后，页面确认会生成 root 私有的不可变 `config.env`，任务详情显示实际路径。该配置与状态目录用于事后核查，不能用修改后的草稿覆盖；详见 [Web 部署指南](web-deployment.md)。

## 1. 确定同一份配置文件

以下三条路径择一。先完成新环境/已有集群的判断，目录须为受控位置，路径不能有中文、空格或 `..`，不要覆盖已有集群绑定文件。

### 从 Web 导出

1. 普通用户启动 Web，填写或导入、保存草稿，并完成参数校验和计划审阅。
2. 点击“导出 env”。浏览器下载的是配置文件；**保存草稿本身不会写入项目的 `cluster-vars.env`**。
3. 将导出文件保存到已准备且自己有权写入的受控目录。例如本例使用 `/srv/rise-config/site-new.env`；按实际保存位置替换，不要照抄不存在的路径。
4. 审阅文件中的节点、路径和模式，确认它不包含密码值、私钥正文或可执行 Shell 语句。只对这份新导出文件设置私有权限：

```bash
set -e
CONFIG=/srv/rise-config/site-new.env
test -f "$CONFIG"
test -r "$CONFIG"
chmod 600 "$CONFIG"
```

不要用 Web 导入副本覆盖旧集群现场配置。Web 无法判断它来自哪个已部署环境，也不会迁移旧回执。

### 从 CLI 向导生成

直接运行 `sudo bash deploy.sh` 时，向导默认保存到当前项目根目录的 `cluster-vars.env`。在项目目录中明确绑定该路径：

```bash
CONFIG="$PWD/cluster-vars.env"
```

如果启动时传入了 `--env /absolute/path/site.env`，则 CONFIG 应指向那个文件，而非默认文件。向导以 sudo 运行时，新文件通常为 root 所有、0600；后续检查必须使用有权限读取它的身份。向导保存配置不等于已经部署，最终执行前仍有确认。

如果只想生成后复核，可使用 `bash deploy.sh render --wizard --env /absolute/path/new-site.env`，保存后退出再检查。该命令会写本地预览，向导可能只读识别节点，不能作为完全无节点连接的演练命令。

### 从模板准备

事先由管理员准备受控父目录，目标文件必须不存在。以下复制操作不会替换已有文件：

```bash
set -e
CONFIG=/srv/rise-config/site-new.env
test ! -e "$CONFIG"
test ! -L "$CONFIG"
(umask 077; set -C; cat cluster-vars.env.example > "$CONFIG")
```

外部 Harbor 使用 `examples/external-harbor.env` 替代上述模板。填写完整拓扑、离线制品、路径和仓库参数后再继续；模板地址是示例。密码通过正式 CLI 隐藏输入或受控进程环境提供，节点 `password_env` 只写变量名。

## 2. 按文件所有者选择只读检查身份

CLI 会由 Bash source 加载 env。即使命令名是 config-check 或 plan，未知 env 仍可能执行其内的 Shell 语句；先核对来源和内容，再交给相应身份读取。Web 受限导入是另一条不执行上传原文的数据解析路径。

如果 CONFIG 由当前普通用户保管，且文件及父目录均可读/可遍历，在项目目录执行：

```bash
set -e
CONFIG=/srv/rise-config/site-new.env
test -n "$CONFIG"
test -f "$CONFIG"
test -r "$CONFIG"
bash deploy.sh config-check --env "$CONFIG" --json
bash deploy.sh plan --env "$CONFIG" --json
```

如果 CONFIG 是 sudo 向导生成的 root 私有文件，已审阅的可信配置由获授权管理员读取：

```bash
set -e
CONFIG="$PWD/cluster-vars.env"
sudo test -f "$CONFIG"
sudo test -r "$CONFIG"
sudo bash deploy.sh config-check --env "$CONFIG" --json
sudo bash deploy.sh plan --env "$CONFIG" --json
```

使用自定义路径时替换 CONFIG。不要为了普通用户读取而将已有配置改为 0644、递归 chmod state/runs 或改变原回执所有者。Web 始终以普通用户启动，不能用 sudo 启动 Web 来读取 root 配置。需要让另一人审阅时，按本地权限管理制度提供受控副本，而不是改变生产文件保护。

两种只读命令都不连接节点、不安装、不建立阶段成功记录；返回 JSON 的 `execution_authorized=false` 和 `live_checks_performed=false` 应保持为 false。它们不证明实际 SSH、sudo、磁盘、依赖、仓库、身份或健康已通过。

## 3. 显式加载后进入统一菜单

只有新环境前置条件和配置审阅均完成后，才执行：

```bash
CONFIG=/srv/rise-config/site-new.env
sudo bash deploy.sh --env "$CONFIG"
```

选择“安装 → 使用已有配置范围 → 复用”，核对摘要再确认。默认向导文件也可明确传入 `--env "$PWD/cluster-vars.env"`。`--env` 使用指定文件，不会自动上传、复制或同步 Web 草稿；修改草稿后应另行导出、审阅，不能覆盖已绑定的配置继续首装。

不要把 `CONFIG=...` 写在 sudo 之后当成工具参数，也不要依赖 sudo 自动继承普通用户的密码变量。正式密码读取方法和自动化约束见 [交互式部署指南](deploy-guide.md)。

## 4. 配置与状态读取失败的处理

- `--env 需要参数值`：当前终端没有设置 CONFIG，或值为空；按实际文件路径重新赋值。
- `Permission denied`：先确认文件所有者、父目录遍历权限及当前身份；使用有权读取的管理员，不放宽现场文件权限。
- `status` 显示状态未知/读取失败并返回非零：无法核实本地记录，不代表没有集群；核对原 STATE_DIR 和读取身份。
- 参数或指纹不匹配：保留原文件、备份和回执，按 [维护手册](operations.md) 判断；不删除 state 或更名来绕过。

状态检查不 source env。自定义状态目录用 `bash deploy.sh status --state-dir /absolute/path/state-base`；root 保管的记录由管理员以 sudo 执行同一只读命令。即使明确没有本地记录，也仍须检查现场是否存在其他部署工具创建的集群和数据。
