#!/usr/bin/env bash
# All connections are proven before any public key is distributed.
ssh_key_preflight() {
    need python3
    SSH_PUBLIC_KEY=$(python3 "$ROOT/lib/ssh-key-policy.py" "$SSH_AUTH_MODE" "$SSH_KEY") ||
        die '部署 SSH 密钥检查失败；原文件保留，请核对路径、权限、公私钥配对和加密状态'
}
access_has_ssh_nodes() {
    local row
    while IFS= read -r row; do
        parse_node "$row"
        [ "$NODE_CONNECTION" != ssh ] || return 0
    done < <(node_lines)
    return 1
}
access_run() {
    local row failed=0 bootstrap name pub
    # This is a controller-local check, before the first node operation. local
    # nodes and persistent-password mode neither need nor generate an SSH key.
    if [[ "$SSH_AUTH_MODE" = bootstrap || "$SSH_AUTH_MODE" = key ]] && access_has_ssh_nodes; then
        ssh_key_preflight || die '部署 SSH 密钥检查失败；尚未访问节点'
    fi
    : > "$RUN_DIR/access.jsonl" || die '无法创建接入记录'
    while IFS= read -r row; do
        parse_node "$row"; bootstrap=0
        if [ "$SSH_AUTH_MODE" = password ] && [ "$NODE_CONNECTION" = ssh ]; then
            [ -n "$NODE_PASS_ENV" ] || die "$NODE_NAME 密码模式需要第13列的密码变量名"
            if [ -z "${!NODE_PASS_ENV:-}" ] && [ "$NONINTERACTIVE" != true ]; then ask_secret "$NODE_PASS_ENV" "$NODE_NAME SSH 密码（隐藏输入）: "; fi
        fi
        if ! node_run "$ROOT/node_scripts/access-probe.sh" > "$RUN_DIR/$NODE_NAME.probe" 2> "$RUN_DIR/$NODE_NAME.access.log"; then
            if [ "$SSH_AUTH_MODE" != bootstrap ] || [ "$NODE_CONNECTION" != ssh ]; then failed=1; continue; fi
            if [ -z "$NODE_PASS_ENV" ]; then NODE_PASS_ENV=RISE_SSH_PASSWORD; fi
            if [ -z "${!NODE_PASS_ENV:-}" ] && [ "$NONINTERACTIVE" != true ]; then ask_secret "$NODE_PASS_ENV" "$NODE_NAME SSH 密码（隐藏输入）: "; fi
            if ! BOOTSTRAP=1 node_run "$ROOT/node_scripts/access-probe.sh" > "$RUN_DIR/$NODE_NAME.probe" 2>> "$RUN_DIR/$NODE_NAME.access.log"; then failed=1; continue; fi
            bootstrap=1
        fi
        printf '%s\n' "$bootstrap" > "$RUN_DIR/$NODE_NAME.bootstrap" || die '无法保存接入方式记录'
        # Store identity only, never the password or the process environment.
        jq -Rn --arg name "$NODE_NAME" --arg ip "$NODE_INTERNAL" --arg arch "$NODE_ARCH" \
            '[inputs]|{name:$name,ip:$ip,arch:$arch,machine_id:.[0],uuid:.[1],hostname:.[2]}' \
            < "$RUN_DIR/$NODE_NAME.probe" >> "$RUN_DIR/access.jsonl" || die '无法保存节点身份记录'
    done < <(node_lines)
    [ "$failed" = 0 ] || die '部分节点 SSH/sudo 接入失败；未分发公钥，查看各节点 access.log'
    jq -s . "$RUN_DIR/access.jsonl" > "$RUN_DIR/access.json" || die '无法汇总节点身份记录'
    jq -e 'length>0 and all(.[]; (.machine_id|length)>0 and (.hostname|length)>0) and
        (group_by(.machine_id)|all(.[];length==1)) and
        (map(select(.uuid!=""))|group_by(.uuid)|all(.[];length==1))' "$RUN_DIR/access.json" >/dev/null || die '节点身份为空或重复'
    if [ -f "${WF_DIR:-$RUN_DIR}/access-identity.json" ]; then
        [ "$(sha256_file "$WF_DIR/access-identity.json")" = "$(cat "$WF_DIR/access-identity.sha256")" ] || die '原接入身份记录已改变'
        component_compare_prepared_identity "$WF_DIR/access-identity.json" "$RUN_DIR/access.json" || die '节点接入身份与原基线不符'
    fi
    if [ "$SSH_AUTH_MODE" = bootstrap ] && access_has_ssh_nodes; then
        pub="$SSH_PUBLIC_KEY"
        # Check every target's key file before writing any target. Each append
        # rechecks under a lock, so intervening changes still fail closed.
        while IFS= read -r row; do
            parse_node "$row"; [ "$NODE_CONNECTION" = ssh ] || continue
            bootstrap=$(cat "$RUN_DIR/$NODE_NAME.bootstrap")
            [ -n "$NODE_PASS_ENV" ] || NODE_PASS_ENV=RISE_SSH_PASSWORD
            BOOTSTRAP="$bootstrap" RUN_AS_USER=1 node_run "$ROOT/node_scripts/keys.sh" --check "$pub" > "$RUN_DIR/$NODE_NAME.key-policy.log" 2>&1 ||
                die "$NODE_NAME 公钥策略预检失败；尚未分发公钥，查看节点 key-policy.log"
        done < <(node_lines)
        while IFS= read -r row; do
            parse_node "$row"; [ "$NODE_CONNECTION" = ssh ] || continue
            bootstrap=$(cat "$RUN_DIR/$NODE_NAME.bootstrap")
            [ -n "$NODE_PASS_ENV" ] || NODE_PASS_ENV=RISE_SSH_PASSWORD
            BOOTSTRAP="$bootstrap" RUN_AS_USER=1 node_run "$ROOT/node_scripts/keys.sh" "$pub" >> "$RUN_DIR/$NODE_NAME.key-policy.log" 2>&1 ||
                die "$NODE_NAME 公钥追加失败；保留已完成节点与 key-policy.log，不删除原授权"
            node_run "$ROOT/node_scripts/access-probe.sh" > "$RUN_DIR/$NODE_NAME.after" 2>> "$RUN_DIR/$NODE_NAME.key-policy.log" ||
                die "$NODE_NAME 公钥接入复验失败；保留原授权和 key-policy.log"
            cmp -s "$RUN_DIR/$NODE_NAME.probe" "$RUN_DIR/$NODE_NAME.after" || die "$NODE_NAME 密钥接入后的身份发生变化"
        done < <(node_lines)
    fi
}
