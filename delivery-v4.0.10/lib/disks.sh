#!/usr/bin/env bash
# Presentation only. Keep byte sizes in candidate files for the destructive gate.
DISK_CAPACITY_AWK='
function capacity(v, n,i,u,a) {
    if (v=="" || v=="-" || v=="null") return "-";
    if (v ~ /^[0-9]+([.][0-9]+)?[KMGTPE]$/) {
        u=substr(v,length(v),1); n=substr(v,1,length(v)-1);
        return n " " u "iB";
    }
    if (v !~ /^[0-9]+([.][0-9]+)?$/) return v;
    n=v+0; split("B KiB MiB GiB TiB PiB EiB",a," "); i=1;
    while(n>=1024 && i<7) {n/=1024;i++}
    return sprintf((n==int(n) ? "%.0f %s" : "%.1f %s"),n,a[i]);
}'
disk_capacity() { printf '%s\n' "$1" | awk "$DISK_CAPACITY_AWK"'{print capacity($0)}'; }
disk_candidates() {
    jq -r '.blockdevices[]|select(.type=="disk" and ((.children//[])|length)==0 and (.fstype//"")=="" and (.mountpoint//"")=="" and ((.mountpoints//[])|map(select(.!=null and .!=""))|length)==0 and (.ro==false or .ro==0)) | [.name,.size,(.model//"-"),(.serial//"-")]|@tsv' "$1"
}
# Align Chinese headers and ASCII device paths without requiring column(1).
disk_table() {
    jq -Rrs '
      def width: [explode[] | if (.>=11904 and .<=42191) or (.>=44032 and .<=55203) or (.>=65281 and .<=65376) then 2 else 1 end] | add // 0;
      def row($widths): . as $r | [range(0;($widths|length)) as $i | ($r[$i] + (" " * ($widths[$i]-($r[$i]|width))))] | join("  ");
      split("\n") | map(select(length>0)|split("\t")) as $rows |
      if ($rows|length)>0 then
        ($rows|transpose|map(map(width)|max)) as $widths |
        ($rows[0]|row($widths)),
        ($widths|map("-" * .)|join("  ")),
        ($rows[1:][]|row($widths)),
        (if ($rows|length)==1 then "（无记录）" else empty end)
      else empty end'
}
show_storage_overview() {
    local name="$1" address="$2" blocks="$3" mounts="$4" candidates="$5"
    printf '\n节点：%s（%s）\n\n磁盘概览\n' "$name" "$address"
    {
        printf '设备\t容量\t文件系统\t挂载点\t状态\n'
        jq -r --rawfile candidates "$candidates" '
          def tree: recurse(.children[]?);
          ($candidates|split("\n")|map(select(length>0)|split("\t")[0])) as $names |
          .blockdevices[] | select(.type=="disk") | . as $disk |
          [tree] as $parts |
          ([$parts[]|(.mountpoint//empty),(.mountpoints//[])[]|select(.!=null and .!="")]|unique) as $points |
          ([$parts[]|.fstype//empty|select(.!="")]|unique) as $fs |
          ($names|index($disk.name)) as $number |
          (if ($points|index("/")) then "系统盘，禁止格式化"
           elif (.ro==true or .ro==1) then "只读，不可选"
           elif ((.children//[])|length)>0 or ($fs|length)>0 or ($points|length)>0 then "已有分区/数据，人工确认"
           elif $number!=null then "候选空盘 [\($number+1)]"
           else "需人工复核" end) as $state |
          [.name,.size,($fs|join(",")|if .=="" then "—" else . end),($points|join(",")|if .=="" then "—" else . end),$state]|@tsv
        ' "$blocks" | awk -F '\t' "$DISK_CAPACITY_AWK"'{printf "%s\t%s\t%s\t%s\t%s\n",$1,capacity($2),$3,$4,$5}'
    } | disk_table
    printf '\n已有磁盘挂载\n'
    {
        printf '设备\t挂载点\t文件系统\t总容量\t可用空间\t说明\n'
        jq -r '[.filesystems[]|recurse(.children[]?)|
          select((.source//""|startswith("/dev/")) and (.source|test("^/dev/(loop|sr)[0-9]")|not) and
            (.fstype//""|test("^(tmpfs|devtmpfs|iso9660|squashfs)")|not))] |
          unique_by([.target,.source])|.[]|
          [.source,.target,.fstype,(.size//"-"),(.avail//"-"),
           (if .target=="/" or .target=="/boot" or .target=="/boot/efi" then "系统挂载"
            elif (.options//""|split(",")|index("ro")) then "只读"
            elif .fstype=="ext4" then "ext4，需核验独立挂载与已有数据"
            elif .fstype=="xfs" then "XFS，需 xfs_info 证明 ftype=1"
            else "不支持运行时数据盘" end)]|@tsv
        ' "$mounts" | awk -F '\t' "$DISK_CAPACITY_AWK"'{printf "%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,capacity($4),capacity($5),$6}'
    } | disk_table
    if [ ! -s "$candidates" ]; then
        printf '\n未发现候选空盘。仅使用系统盘时可明确选择 native；已有独立 ext4 或已证明 ftype=1 的 XFS 数据挂载盘可选择 existing。不会自动格式化。\n'
    fi
    printf '\n已隐藏虚拟设备和光驱；原始数据保留在节点报告中。\n\n'
}
show_format_confirmation() {
    local name="$1" address="$2" device="$3" size="$4" model="$5" serial="$6" target="$7"
    printf '\n┌─ 即将格式化 ──────────────────────────\n'
    printf '│ 节点：      %s（%s）\n' "$name" "$address"
    printf '│ 设备：      %s\n' "$device"
    printf '│ 容量：      %s\n' "$(disk_capacity "$size")"
    [ -z "$model" ] || [ "$model" = - ] || printf '│ 型号：      %s\n' "$model"
    [ -z "$serial" ] || [ "$serial" = - ] || printf '│ 序列号：    %s\n' "$serial"
    printf '│ 分区方案：  GPT 单分区\n'
    printf '│ 文件系统：  ext4\n'
    printf '│ 挂载目录：  %s\n' "$target"
    printf '│ 操作结果：  清除所选设备上的全部数据\n'
    printf '└──────────────────────────────────────\n\n'
}
recommended_storage_mode() {
    # Collection has no xfs_info evidence. Do not recommend an unverified XFS
    # mount; explicit existing mode will verify ftype=1 on the target node.
    jq -nr --slurpfile blocks "$1" --slurpfile mounts "$2" '
      [$mounts[0].filesystems[]|recurse(.children[]?)] as $fs |
      ([$fs[]|select(.target=="/")|.source|split("[")[0]][0]//"") as $root |
      ([$fs[]|select((.source//""|startswith("/dev/")) and (.source|test("^/dev/(loop|sr)[0-9]")|not) and .target!="/" and .target!="/boot" and .target!="/boot/efi" and (.source|split("[")[0])!=$root and .fstype=="ext4" and ((.options//""|split(",")|index("ro"))==null))]|length) as $data |
      [$blocks[0].blockdevices[]|select(.type=="disk")] as $disks |
      if $data>0 then "existing"
      elif ($disks|length)==1 and ([$disks[]|recurse(.children[]?)|select(.mountpoint=="/" or ((.mountpoints//[])|index("/")))]|length)>0 then "native"
      else "choose" end'
}
