#!/usr/bin/env bash
# 完整初始化成功后，保存“用户配置 → 生效快照”的私有索引。
# 用户仍只维护 cluster-vars.env；索引不含密码，不作为集群部署成功的凭据。
# 原配置与快照均校验 SHA256，避免更改节点后沿用旧磁盘选择。

prepared_source_path() {
    [ -f "$1" ] || die "找不到现场配置：${1}；请从主菜单生成配置"
    printf '%s/%s\n' "$(cd -- "$(dirname -- "$1")" && pwd -P)" "$(basename -- "$1")"
}
prepared_index_path() {
    local source="$1" key
    # 按绝对配置路径隔离多个现场配置；只读查找不会创建目录。
    if command -v sha256sum >/dev/null 2>&1; then
        key=$(printf '%s' "$source" | sha256sum | awk '{print $1}')
    else
        key=$(printf '%s' "$source" | shasum -a 256 | awk '{print $1}')
    fi
    printf '%s/state/prepared/%s.json\n' "$ROOT" "$key"
}
# 初始化开始修改节点前原子写入 pending，不直接删除成功索引。
# 删除会被 all 误判为“从未初始化”，而 pending 明确要求先完成一次完整 init。
# keys/storage/kernel 单阶段即使成功，也不能证明整套准备仍满足安装条件。
prepared_invalidate() {
    local source index temp
    source=$(prepared_source_path "$1")
    index=$(prepared_index_path "$source")
    umask 077
    mkdir -p "$(dirname "$index")"
    temp=$(mktemp "${index}.XXXXXX")
    jq -n --arg source "$source" --arg run "${RUN_DIR:-}" --arg stage "${stage:-all}" \
        '{version:1,status:"pending",source:$source,run:$run,stage:$stage}' > "$temp"
    chmod 600 "$temp"; mv "$temp" "$index"
}
prepared_publish() {
    local source effective index temp expected="${3:-}"
    source=$(prepared_source_path "$1")
    effective=$(prepared_source_path "$2")
    [ -z "$expected" ] || [ "$(sha256_file "$source")" = "$expected" ] || die '初始化期间原配置发生变化；未发布索引，请核对运行目录再继续'
    index=$(prepared_index_path "$source")
    umask 077
    mkdir -p "$(dirname "$index")"
    temp=$(mktemp "${index}.XXXXXX")
    jq -n --arg source "$source" --arg effective "$effective" \
        --arg components "${COMPONENTS:-all}" --arg source_sha256 "$(sha256_file "$source")" --arg effective_sha256 "$(sha256_file "$effective")" \
        '{version:1,status:"complete",components:$components,source:$source,effective:$effective,source_sha256:$source_sha256,effective_sha256:$effective_sha256}' > "$temp"
    chmod 600 "$temp"
    mv "$temp" "$index"
    log '初始化参数已自动保存；后续使用同一个 --env 文件即可，无需复制 effective.env'
}
prepared_resolve() {
    local source index effective
    source=$(prepared_source_path "$1")
    PREPARED_ENV="$source"
    PREPARED_FOUND=false
    index=$(prepared_index_path "$source")
    [ -f "$index" ] || return 0
    need jq
    [ "$(jq -r '.status // "complete"' "$index")" != pending ] || die "初始化尚未完整完成：$(jq -r '.run // "未知运行目录"' "$index")；请核对日志后重新执行完整 init，不能复用旧准备结果"
    jq -e --arg source "$source" '.version==1 and .source==$source and (.effective|type=="string")' "$index" >/dev/null || die "初始化索引损坏：${index}；请核对原运行记录"
    [ "$(sha256_file "$source")" = "$(jq -r .source_sha256 "$index")" ] || die '现场配置已有变化；请先预览和核对节点，再用 init 重新初始化；已有集群请使用扩容或重建流程'
    [ "$(jq -r .components "$index")" = "${COMPONENTS:-all}" ] || die '初始化记录的组件范围与本次操作不同；请使用对应 --components 范围，或核对后重新初始化'
    effective=$(jq -r .effective "$index")
    [ -f "$effective" ] || die "生效配置丢失：${effective}；请恢复原 runs/，不要跳过检查继续安装"
    [ "$(sha256_file "$effective")" = "$(jq -r .effective_sha256 "$index")" ] || die "生效快照已有变化：${effective}；请恢复原始快照或核对后重新初始化"
    PREPARED_ENV="$effective"
    PREPARED_FOUND=true
    log "自动使用初始化后的实际参数：$effective"
}

# 维护操作读取最新部署回执，而不是仅初始化时的旧快照。
# 调用前须 load_env 以确定 STATE_DIR 和组件范围；参数为“是否显式指定 --env”。
# 默认配置是寻找集群的入口，实际节点以回执为准（包含后续扩容节点）。
# 显式文件仅在初始化索引能证明其为未改动的原始输入时自动转换；其他显式文件
# 保持原有逐项比较行为，不能把用户修改悄悄替换成回执从而绕过安全检查。
load_maintenance_env() {
    local explicit="$1" receipt cert_variable
    if [ "$explicit" = true ]; then
        prepared_resolve "$ENV_FILE"
        [ "$PREPARED_FOUND" = true ] || return 0
    fi
    receipt=$(component_receipt_dir)
    [ -f "$receipt/cluster.env" ] || return 0
    load_env "$receipt/cluster.env"
    # 公开参数不保存证书私钥；回执仅记录文件路径，校验仍由原 PKI 检查执行。
    for cert_variable in HARBOR_CA HARBOR_CERT HARBOR_KEY; do
        [ ! -f "$receipt/$cert_variable.path" ] || printf -v "$cert_variable" '%s' "$(cat "$receipt/$cert_variable.path")"
    done
    log "维护操作使用最新部署记录：$receipt"
}
