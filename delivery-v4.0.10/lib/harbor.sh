#!/usr/bin/env bash
# Called on the controller by KubeKey before/after image upload.
set -euo pipefail
umask 077
settings="$1"; action="${2:-projects}"
for cmd in jq curl; do command -v "$cmd" >/dev/null || exit 1; done
jq -e '.targets | type=="array" and length>0 and all(.[]; type=="string" and length>0)' "$settings" >/dev/null || { echo 'Harbor targets 为空或无效' >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
domain="$(jq -er .domain "$settings")"; port="$(jq -er .port "$settings")"
scheme=https; [ "$(jq -r .plain_http "$settings")" = false ] || scheme=http
ca="$(jq -r .ca_file "$settings")"
password="$(jq -er .password "$settings")"
[[ "$password" =~ ^[A-Za-z0-9.!_@%+=:-]{12,128}$ ]] || { echo '仓库密码格式不支持' >&2; exit 1; }
printf 'user = "admin:%s"\n' "$password" > "$tmp/curl.conf"
unset password
if [ "$action" != --health ]; then
selected="$(jq -er .selected_file "$settings")"
jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' "$selected" >/dev/null
jq -r '.[] | sub("^oci://"; "") | capture("^(?<registry>[^/]+)/(?<repo>.+):(?<tag>[^:]+)$") |
  (if .registry == "registry.k8s.io" and (.repo|contains("/")|not) then .repo="kubernetes/"+.repo else . end) |
  [.repo,.tag] | @tsv' "$selected" | sort -u > "$tmp/images.tsv"
[ -s "$tmp/images.tsv" ] || { echo '没有目标镜像' >&2; exit 1; }
fi
api() {
    local address="$1" method="$2" path="$3" payload="${4:-}"; local -a opts=(--globoff)
    if [ "$scheme" = https ]; then opts+=(--cacert "$ca"); fi
    if [ -n "$payload" ]; then opts+=(--data-binary "@$payload" --header 'Content-Type: application/json'); fi
    STATUS="$(curl --config "$tmp/curl.conf" --silent --show-error --connect-timeout 10 --max-time 60 \
        --noproxy "$domain" --resolve "$domain:$port:$address" "${opts[@]}" --request "$method" \
        --output "$tmp/response.json" --write-out '%{http_code}' "$scheme://$domain:$port$path")" || { echo 'Harbor API 网络或证书错误' >&2; exit 1; }
}
wait_health() {
    local address="$1" deadline=$((SECONDS+300))
    while :; do
        api "$address" GET /api/v2.0/health
        if [ "$STATUS" = 200 ] && jq -e '.status=="healthy"' "$tmp/response.json" >/dev/null; then return; fi
        [ "$STATUS" != 401 ] && [ "$STATUS" != 403 ] || { echo 'Harbor 认证失败' >&2; exit 1; }
        [ "$SECONDS" -lt "$deadline" ] || { echo 'Harbor 健康检查超时' >&2; exit 1; }
        sleep 2
    done
}
while IFS= read -r address; do wait_health "$address"; done < <(jq -r '.targets[]' "$settings")
if [ "$action" = --health ]; then
    while IFS= read -r address; do
        api "$address" GET '/api/v2.0/projects?page_size=1'
        [ "$STATUS" = 200 ] || { echo "Harbor 认证失败 HTTP $STATUS" >&2; exit 1; }
    done < <(jq -r '.targets[]' "$settings")
    echo 'Harbor 健康、TLS 与认证检查通过'
    exit 0
fi
if [ "$action" = projects ] || [ "$action" = --projects-check ] || [ "$action" = --verify ] || [ "$action" = --preflight ]; then
    cut -f1 "$tmp/images.tsv" | cut -d/ -f1 | sort -u > "$tmp/projects"
    while IFS= read -r address; do
        while IFS= read -r project; do
            [[ "$project" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo '项目名不合法' >&2; exit 1; }
            api "$address" GET "/api/v2.0/projects/$project"
            if [ "$STATUS" = 404 ] && [ "$action" = projects ]; then
                jq -n --arg name "$project" '{project_name:$name,metadata:{public:"true"}}' > "$tmp/create.json"
                api "$address" POST /api/v2.0/projects "$tmp/create.json"
                [ "$STATUS" = 201 ] || [ "$STATUS" = 409 ] || { echo "创建项目失败: $project HTTP $STATUS" >&2; exit 1; }
                api "$address" GET "/api/v2.0/projects/$project"
            fi
            [ "$STATUS" = 200 ] || { echo "项目查询失败: $project HTTP $STATUS" >&2; exit 1; }
            jq -e '.metadata.public=="true" or .metadata.public==true' "$tmp/response.json" >/dev/null || {
                echo "项目 $project 为私有或属性未知，保持原属性并停止上传，请人工处理" >&2; exit 1;
            }
            printf '项目已就绪: %s %s\n' "$address" "$project"
        done < "$tmp/projects"
    done < <(jq -r '.targets[]' "$settings")
fi
if [ "$action" = --verify ] || [ "$action" = --preflight ]; then
    arches=$(jq -c '.arches // []' "$settings")
    jq -e '.arches | type=="array" and length>0 and all(.[]; .=="amd64" or .=="arm64")' "$settings" >/dev/null || { echo '镜像验收必须指定平台' >&2; exit 1; }
    : > "$tmp/evidence.jsonl"
    verify_timeout="$(jq -r '.verify_timeout // 600' "$settings")"
    [[ "$verify_timeout" =~ ^[0-9]+$ ]] && [ "$verify_timeout" -le 3600 ] || exit 1
    while IFS=$'\t' read -r repository tag; do
        [[ "$repository" = */* ]] || { echo '镜像路径缺少项目' >&2; exit 1; }
        deadline=$((SECONDS+verify_timeout))
        project="${repository%%/*}"; repo="${repository#*/}"
        repo="$(printf '%s' "$repo" | jq -Rr '@uri | @uri')"; tag="$(printf '%s' "$tag" | jq -Rr @uri)"
        while :; do
            : > "$tmp/digests"
            : > "$tmp/iteration.jsonl"
            while IFS= read -r address; do
                api "$address" GET "/api/v2.0/projects/$project/repositories/$repo/artifacts/$tag"
                [ "$STATUS" != 401 ] && [ "$STATUS" != 403 ] || { echo '镜像验收认证失败' >&2; exit 1; }
                if [ "$STATUS" = 200 ]; then
                    jq -e '.digest | type=="string" and test("^sha256:[0-9a-f]{64}$")' "$tmp/response.json" >/dev/null || {
                        echo "无效镜像摘要: $repository" >&2; exit 1;
                    }
                    jq -r .digest "$tmp/response.json" >> "$tmp/digests"
                    jq -e --argjson required "$arches" '
                      ([.references[]?.platform | select(.os=="linux") | .architecture] +
                       [select(.extra_attrs.os=="linux") | .extra_attrs.architecture]) | unique as $present |
                      all($required[]; . as $arch | $present|index($arch)!=null)' "$tmp/response.json" >/dev/null || {
                        echo "镜像架构缺失或元数据不可核验: ${repository}（需要 ${arches}）" >&2; exit 1;
                    }
                    jq -c --arg target "$address" --arg repository "$repository" --arg tag "$tag" \
                        '{target:$target,repository:$repository,tag:$tag,digest:.digest,references:(.references // []),
                          platforms:([.references[]?.platform]+[select(.extra_attrs.os!=null)|.extra_attrs|{os,architecture}])}' \
                        "$tmp/response.json" >> "$tmp/iteration.jsonl"
                else echo MISSING >> "$tmp/digests"; fi
            done < <(jq -r '.targets[]' "$settings")
            if ! grep -qx MISSING "$tmp/digests" && [ "$(sort -u "$tmp/digests" | wc -l | tr -d ' ')" = 1 ]; then cat "$tmp/iteration.jsonl" >> "$tmp/evidence.jsonl"; break; fi
            [ "$SECONDS" -lt "$deadline" ] || { echo "镜像尚未同步: $repository" >&2; exit 1; }
            sleep 2
        done
    done < "$tmp/images.tsv"
    evidence=$(jq -r '.evidence_file // empty' "$settings")
    if [ -n "$evidence" ]; then
        jq -s --argjson arches "$arches" '{schema:1,required_arches:$arches,images:.}' "$tmp/evidence.jsonl" > "$evidence.tmp"
        chmod 600 "$evidence.tmp"; mv "$evidence.tmp" "$evidence"
    fi
    echo '各 Harbor 实例镜像标签、有效摘要和所需架构验收通过' 
elif [ "$action" != projects ] && [ "$action" != --projects-check ]; then
    echo '未知 Harbor 操作' >&2; exit 1
fi
