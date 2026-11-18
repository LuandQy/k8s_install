#!/usr/bin/env bash
progress_step() { printf '[阶段 %s] %s\n' "$1" "$2" >&2; }
progress_clean() { LC_ALL=C sed -E $'s/\033\\[[0-9;?]*[[:alpha:]]//g' | tr '\r' '\n'; }
# 日志与进度不做脱敏（交付方明确取舍）：完整命令、密码和私钥路径都可能出现。
# 只对终端转义和超长行做清理，保留可诊断的原始信息。
progress_tail() {
    # Drop the first partial line when the byte window starts mid-line, so the
    # summary never prints half a line; content itself is not redacted.
    LC_ALL=C tail -c 65537 "$1" | LC_ALL=C awk '
        {lines[NR]=$0; size+=length($0)+1}
        END {first=(size>65536?2:1); for(i=first;i<=NR;i++) print lines[i]}'
}
progress_last_task() {
    # Redact before truncating: a long credential must not leak as a partial prefix.
    progress_tail "$1" | progress_clean | awk '/\[roles\// && /\] / {task=$0} /\[[a-zA-Z0-9_.-]+\][[:space:]]+(running|success|failed|skip)/ {node=$0;sub(/^[^[]*/,"",node);node=substr(node,1,100)} END{if(task!=""){printf "%s",substr(task,1,800);if(node!="")printf " | %s",node;print ""}}'
}
progress_error_lines() {
    local file="$1"
    [ -f "$file" ] || return 0
    # Select diagnostics, not arbitrary stdout or shell tracing/command arguments.
    progress_tail "$file" | progress_clean | awk '
        /^[+]/ {next}
        {lower=tolower($0)}
        lower ~ /error|failed|failure|permission denied|access denied|not found|no such file|timed out|timeout|connection refused|unreachable|cannot|could not|password is required|e: / || /缺少|失败|错误|拒绝|不存在|无效|不一致|已占用/ {v[++n]=$0}
        END {start=n-3;if(start<1)start=1;for(i=start;i<=n;i++)print substr(v[i],1,800)}'
}
progress_error_summary() {
    local file="$1" task details
    task=$(progress_last_task "$file") || task=''
    [ -z "$task" ] || printf '[失败任务] %s\n' "$task" >&2
    details=$(progress_error_lines "$file") || details=''
    if [ -n "$details" ]; then printf '%s\n' "$details" >&2
    else printf '未找到可安全摘录的错误行，请查看受限日志。\n' >&2; fi
    printf '完整日志（含受限信息）: %s\n' "$file" >&2
}
progress_run() {
    local label="$1" file="$2" pid status=0 start now last_heartbeat task previous='' last_task='' old_int old_term child_status
    shift 2
    umask 077
    : > "$file"; chmod 600 "$file"
    start=$SECONDS; last_heartbeat=$SECONDS
    printf '[进行中] %s；日志: %s\n' "$label" "$file" >&2
    "$@" > "$file" 2>&1 & pid=$!
    old_int=$(trap -p INT); old_term=$(trap -p TERM)
    trap 'status=130; kill -TERM "$pid" 2>/dev/null || true' INT
    trap 'status=143; kill -TERM "$pid" 2>/dev/null || true' TERM
    while kill -0 "$pid" 2>/dev/null; do
        task=$(progress_last_task "$file") || task=''
        now=$SECONDS
        if [ -n "$task" ]; then last_task="$task"; fi
        if [ -n "$task" ] && [ "$task" != "$previous" ]; then
            printf '[任务] %s（耗时 %ss）\n' "$task" "$((now-start))" >&2
            previous="$task"; last_heartbeat=$now
        elif [ "$((now-last_heartbeat))" -ge "${PROGRESS_HEARTBEAT_SECONDS:-15}" ]; then
            printf '[进行中] %s，耗时 %ss%s\n' "$label" "$((now-start))" "${last_task:+；当前任务: $last_task}" >&2
            last_heartbeat=$now
        fi
        sleep "${PROGRESS_POLL_INTERVAL:-1}"
    done
    wait "$pid" || { child_status=$?; [ "$status" -ne 0 ] || status=$child_status; }
    trap - INT TERM
    [ -z "$old_int" ] || eval "$old_int"
    [ -z "$old_term" ] || eval "$old_term"
    if [ "$status" -eq 0 ]; then
        printf '[完成] %s，耗时 %ss\n' "$label" "$((SECONDS-start))" >&2
    else
        printf '[失败] %s，耗时 %ss，退出码 %s\n' "$label" "$((SECONDS-start))" "$status" >&2
        progress_error_summary "$file"
    fi
    return "$status"
}
