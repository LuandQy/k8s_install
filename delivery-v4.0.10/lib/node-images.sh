#!/usr/bin/env bash
# Verify through the same CRI used by kubelet, after KubeKey installs it.
node_images_verify() {
    local row repo tag digest ref index=0 count=0 authority="$HARBOR_DOMAIN:$HARBOR_PORT"
    jq -er '.images | length>0' "$RUN_DIR/images-evidence.json" >/dev/null || die '仓库镜像验收证据为空'
    jq -r '.images|unique_by(.repository,.tag)|.[]|[.repository,.tag,.digest]|@tsv' "$RUN_DIR/images-evidence.json" > "$RUN_DIR/pull-list.tsv"
    : > "$RUN_DIR/node-images.jsonl"
    while IFS= read -r row; do
        parse_node "$row"
        has_role control_plane || has_role worker || continue
        count=$((count+1)); index=0
        while IFS=$'\t' read -r repo tag digest; do
            index=$((index+1)); ref="$authority/$repo:$tag"
            # The selected platform's child digest is valid for a multiarch index.
            jq --arg repo "$repo" --arg tag "$tag" --arg arch "$NODE_ARCH" \
                '[.images[]|select(.repository==$repo and .tag==$tag)|.digest,
                  (.references[]?|select(.platform.os=="linux" and .platform.architecture==$arch)|.child_digest)]|unique' \
                "$RUN_DIR/images-evidence.json" > "$RUN_DIR/expected-digests.json"
            node_run "$ROOT/node_scripts/image-pull.sh" "$ref" > "$RUN_DIR/$NODE_NAME.image-$index.json" 2> "$RUN_DIR/$NODE_NAME.image-$index.log"
            jq -e --arg repo "$authority/$repo" --slurpfile expected "$RUN_DIR/expected-digests.json" '
                (.status.id|type=="string" and length>0) and
                any(.status.repoDigests[]?; split("@") as $p | $p[0]==$repo and ($expected[0]|index($p[1]))!=null)
                ' "$RUN_DIR/$NODE_NAME.image-$index.json" >/dev/null || die "$NODE_NAME 镜像摘要与 Harbor 验收不符: $ref"
            jq --arg node "$NODE_NAME" --arg arch "$NODE_ARCH" --arg image "$ref" --arg digest "$digest" \
                '{node:$node,arch:$arch,image:$image,registry_digest:$digest,image_id:.status.id,repo_digests:.status.repoDigests,result:"passed"}' \
                "$RUN_DIR/$NODE_NAME.image-$index.json" >> "$RUN_DIR/node-images.jsonl"
        done < "$RUN_DIR/pull-list.tsv"
    done < <(node_lines)
    [ "$count" -gt 0 ] || die '没有可验收的 K8s 节点'
    jq -s '{schema:1,method:"crictl pull + inspecti (existing cache retained)",images:.}' "$RUN_DIR/node-images.jsonl" > "$RUN_DIR/node-images-evidence.json"
}
