#!/usr/bin/env bash
# Optional BYO root CA staging. No secret content is printed or persisted outside
# WORK_DIR/pki; the key is only copied after certificate/key validation.
pki_enabled() { [ -n "${PKI_ROOT_CERT:-}${PKI_ROOT_KEY:-}" ]; }

pki_stage_root() {
    pki_enabled || return 0
    [ -n "${PKI_ROOT_CERT:-}" ] && [ -n "${PKI_ROOT_KEY:-}" ] ||
        die '自带根 CA 需要同时配置 PKI_ROOT_CERT 和 PKI_ROOT_KEY'
    local cert="$PKI_ROOT_CERT" key="$PKI_ROOT_KEY" dir="$WORK_DIR/pki"
    local target_cert="$dir/root.crt" target_key="$dir/root.key" file
    for file in "$cert" "$key"; do
        [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] ||
            die "自带根 CA 文件不存在、不可读或为符号链接: $file"
    done
    need openssl
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 ||
        die 'PKI_ROOT_CERT 不是可解析的 PEM 证书'
    openssl pkey -in "$key" -noout -passin pass: >/dev/null 2>&1 ||
        die 'PKI_ROOT_KEY 不是可解析的无口令 PEM 私钥'
    openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -Eq 'CA:TRUE' ||
        die 'PKI_ROOT_CERT 不是 CA 证书（缺少 CA:TRUE）'
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 ||
        die 'PKI_ROOT_CERT 已过期'
    openssl verify -CAfile "$cert" "$cert" >/dev/null 2>&1 ||
        die 'PKI_ROOT_CERT 不是自签名根证书'
    [ "$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)" = "$(openssl pkey -in "$key" -pubout -passin pass: 2>/dev/null)" ] ||
        die 'PKI_ROOT_CERT 与 PKI_ROOT_KEY 不匹配'
    case "$(file_mode "$key")" in
        400|600|0400|0600) ;;
        *) die 'PKI_ROOT_KEY 必须只允许所有者访问（0400 或 0600）';;
    esac
    install -d -m 700 "$dir"
    if [ -e "$target_cert" ] || [ -e "$target_key" ]; then
        [ -f "$target_cert" ] && [ -f "$target_key" ] ||
            die '现有 PKI 根证书不完整，拒绝覆盖'
        [ "$(sha256_file "$cert")" = "$(sha256_file "$target_cert")" ] &&
        [ "$(sha256_file "$key")" = "$(sha256_file "$target_key")" ] ||
            die '现有 PKI 根 CA 与 PKI_ROOT_* 不一致；不能中途更换根证书'
        chmod 644 "$target_cert"; chmod 600 "$target_key"
        return 0
    fi
    local tmp_cert tmp_key
    tmp_cert="$(mktemp "$dir/.root.crt.XXXXXX")"
    tmp_key="$(mktemp "$dir/.root.key.XXXXXX")"
    cp "$cert" "$tmp_cert"; cp "$key" "$tmp_key"
    chmod 644 "$tmp_cert"; chmod 600 "$tmp_key"
    mv "$tmp_cert" "$target_cert"; mv "$tmp_key" "$target_key"
    log '已校验并安装自带根 CA 到 WORK_DIR/pki；KubeKey 以 IfNotPresent 复用'
}
