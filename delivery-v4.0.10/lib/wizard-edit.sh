#!/usr/bin/env bash
# 按项编辑可信 Bash 配置。整个会话在子进程与临时副本中进行，取消不污染当前参数。
# 保留高级参数、注释及未知自定义字段；只有白名单菜单选中的赋值被替换。
wizard_edit() (
    local target="$1" temp choice value
    load_env "$target"
    # 已开始部署的参数由回执管理，不能用普通编辑制造配置与真实集群不一致。
    # 初始化索引不阻止编辑，但修改后其摘要自然失效，需要重新核对准备结果。
    wizard_assert_editable
    umask 077
    temp=$(mktemp "${target}.edit.XXXXXX")
    trap 'rm -f "$temp"' EXIT
    cp "$target" "$temp"; chmod 600 "$temp"
    while :; do
        # 临时配置允许处于跨字段尚未配齐的中间状态，整体校验放在保存时。
        . "$temp"
        printf '\n按项修改（未选择的字段保持原值）：\n'
        printf '%s\n' '1. 节点与磁盘策略' '2. API 入口' '3. NFS' '4. 版本与域名' '5. 离线归档' '6. 网络、仓库与存储高级参数' '7. 集群名称' '8. SSH 认证与密钥路径' '9. 校验并保存' '0. 取消修改'
        ask_valid '请选择' 0 '0|1|2|3|4|5|6|7|8|9'; choice="$REPLY"
        case "$choice" in
            0) printf '已取消，原配置未修改。\n'; return;;
            1) WIZARD_NODES="$NODES"; CLI_COMPONENTS="$COMPONENTS"; wizard_nodes
               wizard_set "$temp" NODES "$WIZARD_NODES";;
            2)
                case "$ENDPOINT_TYPE" in local) value=1;; kube-vip) value=2;; external) value=3;; haproxy) value=4;; esac
                ask_valid 'API 入口：1 单控制平面；2 kube-vip；3 外部负载均衡；4 haproxy 内置代理（免 VIP）' "$value" '1|2|3|4'
                case "$REPLY" in 1) value=local;; 2) value=kube-vip;; 3) value=external;; 4) value=haproxy;; esac
                wizard_set "$temp" ENDPOINT_TYPE "$value"
                if [ "$value" = kube-vip ] || [ "$value" = external ]; then
                    ask_valid 'API VIP / 外部负载均衡 IP' "$ENDPOINT_ADDRESS" ipv4; wizard_set "$temp" ENDPOINT_ADDRESS "$REPLY"
                    ask_valid 'API 入口端口' "$ENDPOINT_PORT" port; wizard_set "$temp" ENDPOINT_PORT "$REPLY"
                else wizard_set "$temp" ENDPOINT_ADDRESS ''; fi;;
            3)
                case "$NFS_MODE" in none) value=1;; new) value=2;; existing) value=3;; esac
                ask_valid 'NFS：1 不使用；2 清单内节点；3 外部服务' "$value" '1|2|3'
                case "$REPLY" in 1) value=none;; 2) value=new;; 3) value=existing;; esac
                wizard_set "$temp" NFS_MODE "$value"
                if [ "$value" != none ]; then
                    NFS_MODE="$value" nfs_notice
                    if [ "$value" = new ]; then ask_valid 'NFS 服务端节点名' "$NFS_NODE" name; wizard_set "$temp" NFS_NODE "$REPLY"
                    else ask_valid 'NFS 服务端 IP / 域名' "$NFS_SERVER" domain; wizard_set "$temp" NFS_SERVER "$REPLY"; fi
                    ask_valid 'NFS 导出目录' "$NFS_PATH" path; wizard_set "$temp" NFS_PATH "$REPLY"
                fi;;
            4)
                if [ "$COMPONENTS" != harbor ]; then
                    ask_valid 'Kubernetes 版本' "$KUBE_VERSION" version; wizard_set "$temp" KUBE_VERSION "$REPLY"
                    ask_valid 'Kubernetes 域名' "$K8S_DOMAIN" domain; wizard_set "$temp" K8S_DOMAIN "$REPLY"
                fi
                ask_valid 'Harbor 域名' "$HARBOR_DOMAIN" domain; wizard_set "$temp" HARBOR_DOMAIN "$REPLY";;
            5)
                ask_valid '内层离线归档路径' "$ARTIFACT_FILE" file
                value="$(cd -- "$(dirname -- "$REPLY")" && pwd)/$(basename -- "$REPLY")"
                wizard_set "$temp" ARTIFACT_FILE "$value"
                log '计算归档 SHA256，请稍候'; wizard_set "$temp" ARTIFACT_SHA256 "$(sha256_file "$value")";;
            6)
                # 仅提供常见高级字段；复杂证书等配置仍按模板说明人工维护。
                printf '%s\n' '1. Pod 网段' '2. Service 网段' '3. Harbor VIP' '4. 本地 PV 目录' '0. 返回'
                ask_valid '高级参数' 0 '0|1|2|3|4'
                case "$REPLY" in
                    1) ask_default 'Pod CIDR（保存时整体校验）' "$POD_CIDR"; wizard_set "$temp" POD_CIDR "$REPLY";;
                    2) ask_default 'Service CIDR（保存时整体校验）' "$SERVICE_CIDR"; wizard_set "$temp" SERVICE_CIDR "$REPLY";;
                    3) ask_valid 'Harbor VIP' "$HARBOR_VIP" ipv4; wizard_set "$temp" HARBOR_VIP "$REPLY"; wizard_set "$temp" REGISTRY_MODE ha-harbor;;
                    4) ask_valid '本地 PV 目录' "$LOCAL_PATH" path; wizard_set "$temp" LOCAL_PATH "$REPLY";;
                esac;;
            7)
                ask_valid '集群名称（仅允许未部署草稿，默认状态目录随名称变化）' "$CLUSTER_NAME" name
                wizard_set "$temp" CLUSTER_NAME "$REPLY";;
            8)
                case "$SSH_AUTH_MODE" in bootstrap) value=1;; key) value=2;; password) value=3;; esac
                printf 'local 不使用 SSH；免密 SSH 不代表免密 sudo。这里仅修改配置，不检查或分发密钥。\n'
                ask_valid 'SSH 认证：1 配置控制端到节点免密；2 仅用已有密钥；3 持续密码登录' "$value" '1|2|3'
                case "$REPLY" in 1) value=bootstrap;; 2) value=key;; 3) value=password;; esac
                wizard_set "$temp" SSH_AUTH_MODE "$value"
                if [ "$value" != password ]; then
                    ask_valid '执行控制端 SSH 私钥路径（接入阶段再检查存在性与冲突）' "$SSH_KEY" path
                    wizard_set "$temp" SSH_KEY "$REPLY"
                else printf '请在节点第13列填写密码环境变量名；实际密码由后续入口隐藏读取，不写入配置。\n'; fi;;
            9)
                if ! (load_env "$temp"); then printf '尚未保存，请修改上述冲突字段或取消。\n'; continue; fi
                # 临时文件与目标位于同目录，校验通过后再备份和原子替换。
                if cmp -s "$target" "$temp"; then printf '配置未变化。\n'; return; fi
                cp -p "$target" "$target.bak.$(date +%Y%m%dT%H%M%S).$$"
                mv "$temp" "$target"
                printf '配置已保存：%s\n原初始化索引如存在会失效；请先检查再执行。\n' "$target"
                return;;
        esac
    done
)
