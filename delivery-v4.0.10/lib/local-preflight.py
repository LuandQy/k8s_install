"""Read-only local deployment audit. Only report/config files are written.

No installation, mounting, service changes, disk writes, Docker mutations or SSH.
Return 0: no known blocker; 2: blocked/incomplete; 1: audit program failure.
"""
import argparse
import datetime
import hashlib
import html
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time


def safe_error(text):
    text = re.sub(r'(https?://)[^/@\s]+:[^/@\s]+@', r'\1***@', text)
    return re.sub(r'(?i)(password|token|secret)(\s*[=:]\s*)[^\s,;]+', r'\1\2***', text)[-1800:]


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


class Audit:
    def __init__(self, root, output):
        self.root, self.out = root, output
        self.events, self.findings = [], []
        self.can_sudo = os.geteuid() == 0

    def finding(self, code, level, message, action, scope='all'):
        self.findings.append(dict(code=code, level=level, scope=scope, message=message, action=action))

    def run(self, key, label, args, timeout=30, privileged=False):
        started = time.monotonic()
        print(f'[检测 {len(self.events)+1}] {label}', flush=True)
        if privileged and self.can_sudo and os.geteuid() != 0:
            args = ['sudo', '-n'] + args
        try:
            p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout, env=dict(os.environ, LC_ALL='C'))
            code, stdout, error = p.returncode, p.stdout, safe_error(p.stderr)
        except subprocess.TimeoutExpired:
            code, stdout, error = 124, '', f'检测超过 {timeout} 秒，未判定通过'
        except OSError as e:
            code, stdout, error = 127, '', safe_error(str(e))
        # ss can return zero after failing to open netlink. Do not certify its
        # partial /proc fallback output as a complete port check.
        usable=code==0 and not re.search(r'permission denied|operation not permitted|cannot open netlink|failed to connect|no new privileges',error,re.I)
        event = dict(check=key, label=label, status='passed' if usable else 'unknown',
                     exit_code=code, elapsed_seconds=round(time.monotonic()-started, 2), error=error,
                     stdout_log=key+'.stdout', stderr_log=key+'.stderr')
        self.events.append(event)
        write_json(self.out/'checks.json', self.events)
        print(f'[{"完成" if usable else "未通过"}] {label}；退出码 {code}；耗时 {event["elapsed_seconds"]}s' +
              (f'；{error}' if error else ''), flush=True)
        # Raw outputs only come from fixed read-only commands, without secrets/config dumps.
        (self.out/(key+'.stdout')).write_text(stdout)
        (self.out/(key+'.stderr')).write_text(error)
        return dict(returncode=code if code else 0 if usable else 1, actual_returncode=code, stdout=stdout, error=error)

    def json_command(self, key, label, args, **kwargs):
        result = self.run(key, label, args, **kwargs)
        if result['returncode'] != 0:
            return None
        try:
            return json.loads(result['stdout'])
        except ValueError:
            self.events[-1].update(status='unknown', error='返回无效 JSON，无法判定检查通过')
            write_json(self.out/'checks.json', self.events)
            print('[未通过] '+label+'：返回无效 JSON，原始输出已保留', flush=True)
            self.finding(key.upper()+'_INVALID', 'unknown', label+' 返回无效 JSON', '保留日志，修复检测命令后重跑')
            return None

    def directory(self, path):
        p = Path(path); result = dict(path=path, exists=None, symlink=None)
        try:
            p.lstat()
            result.update(exists=True, symlink=p.is_symlink())
        except FileNotFoundError:
            result['exists'] = False
            return result
        except OSError as e:
            result.update(content_status='unknown', error=safe_error(str(e)))
            return result
        try:
            stat = p.stat(); result.update(owner_uid=stat.st_uid, mode=oct(stat.st_mode & 0o777))
            with os.scandir(p) as entries:
                result['top_level_entries'] = sum(1 for _ in entries)
        except OSError as e:
            result['content_status'] = 'unknown'; result['error'] = safe_error(str(e))
        if path in ('/var/lib/docker', '/var/lib/containerd') and (self.can_sudo or os.access(path, os.R_OK)):
            size = self.run('size-'+p.name, '只读统计 '+path+' 数据用量', ['du', '-sx', '--block-size=1', path], timeout=45, privileged=True)
            if size['returncode'] == 0:
                result['bytes'] = int(size['stdout'].split()[0])
        return result

    def prepared_storage(self, host):
        """Recognize storage.sh output without mounting, changing links or files."""
        try:
            mode=Path('/etc/kubekey/rise/storage-mode').read_text().strip()
        except FileNotFoundError:return None
        except OSError as e:
            self.finding('PREPARED_STORAGE_UNKNOWN','unknown','无法读取存储准备标记：'+safe_error(str(e)),'以管理权限只读复核')
            return None
        if mode!='existing':return None
        links={'/var/lib/docker':'docker','/var/lib/containerd':'containerd',
               '/var/lib/kubelet':'kubelet','/var/lib/harbor/data':'harbor'}
        try:
            resolved={source:str(Path(source).resolve(strict=True)) for source in links if Path(source).is_symlink()}
            target=prepared_link_root(resolved)
            if target is None or not all(Path(source).is_dir() for source in links):
                raise ValueError('四个组件软链接缺失或未指向同一数据根')
            if os.stat(target).st_dev==os.stat('/').st_dev:
                raise ValueError('软链接目标仍位于系统根分区')
            mount=self.json_command('prepared-data-mount','核实已准备数据盘挂载',
                ['findmnt','-J','-b','-T',target,'-o','TARGET,SOURCE,FSTYPE,UUID,OPTIONS,SIZE,AVAIL'])
            records=(mount or {}).get('filesystems',[])
            if len(records)!=1 or not persistent_mount_matches(records[0],host.get('fstab')):
                raise ValueError('数据盘挂载与 fstab 的 UUID/设备/文件系统未匹配')
            fs=self.run('prepared-data-filesystem','核实已准备数据盘 Linux 文件系统',
                ['bash',str(self.root/'node_scripts/storage.sh'),'filesystem-check',target])
            if fs['returncode']:raise ValueError(fs['error'] or '文件系统检查失败')
            return dict(path=target,mount=records[0],links=resolved,status='verified_read_only')
        except (OSError,ValueError) as e:
            self.finding('PREPARED_STORAGE_UNKNOWN','unknown','existing 存储准备状态未通过复核：'+safe_error(str(e)),
                         '核对软链接、独立挂载及 fstab；本次不会修复或挂载')
            return None

    def host(self):
        permission = self.run('sudo', '验证非交互管理权限（不修改系统）', ['sudo', '-n', 'true']) if os.geteuid() else {'returncode':0}
        self.can_sudo = os.geteuid() == 0 or permission['returncode'] == 0
        if not self.can_sudo:
            self.finding('ADMIN_ACCESS', 'blocker', '当前检测上下文无法非交互 sudo；部分磁盘/运行时数据无法读取',
                         '在有权限的终端以 sudo 运行同一 preflight；不要把密码写入配置或命令历史')
        release = {}
        for line in Path('/etc/os-release').read_text().splitlines():
            if '=' in line:
                key, value = line.split('=', 1); release[key] = value.strip('"')
        memory = int(re.search(r'^MemTotal:\s+(\d+)', Path('/proc/meminfo').read_text(), re.M)[1])*1024
        host = dict(os=release.get('PRETTY_NAME'), os_id=release.get('ID'), os_version=release.get('VERSION_ID'),
                    kernel=os.uname().release, architecture=os.uname().machine, hostname=os.uname().nodename,
                    cpu_threads=os.cpu_count(), memory_bytes=memory, uid=os.geteuid(), can_sudo=self.can_sudo)
        host['no_new_privileges']=bool(re.search(r'^NoNewPrivs:\s+1$',Path('/proc/self/status').read_text(),re.M))
        if host['no_new_privileges']:
            self.finding('RESTRICTED_CONTEXT','unknown','当前进程受 no_new_privileges 限制；挂载/网络/服务视图可能是沙箱视图',
                         '在真实主机终端复检；沙箱权限失败不能证明主机服务不存在或系统盘实际只读')
        if (host['os_id'], host['os_version'], host['architecture']) != ('ubuntu', '24.04', 'x86_64'):
            self.finding('HOST_PLATFORM', 'blocker', '本机与 Ubuntu 24.04 amd64 预检模板不匹配', '选择匹配系统/架构的离线制品和配置')
        host['blocks'] = self.json_command('blocks', '读取磁盘型号、分区、文件系统和挂载',
            ['lsblk','-b','-J','-p','-e','7','-o','NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,FSTYPE,UUID,MOUNTPOINTS,RO,PKNAME'])
        if host['blocks'] is None:
            self.finding('DISKS_UNKNOWN', 'unknown', '无法核实磁盘拓扑', '检查 lsblk 权限/版本，禁止凭设备名选择数据盘')
        host['root_mount'] = self.json_command('root-mount', '核实系统盘文件系统', ['findmnt','-J','-b','-T','/','-o','TARGET,SOURCE,FSTYPE,SIZE,AVAIL'])
        if not (host['root_mount'] or {}).get('filesystems'):
            self.finding('ROOT_MOUNT_UNKNOWN', 'unknown', '系统盘挂载信息未核实', '查看 root-mount 日志后重跑', scope='native')
        filesystem = self.run('native-filesystem', '核实原生运行时目录的文件系统',
                             ['bash', str(self.root/'node_scripts/storage.sh'), 'filesystem-check', '/var/lib'])
        if filesystem['returncode']:
            restricted_readonly=host['no_new_privileges'] and '只读文件系统' in filesystem['error']
            self.finding('NATIVE_FILESYSTEM', 'unknown' if restricted_readonly else 'blocker',
                         '检测上下文显示 /var/lib 只读，无法判定主机真实挂载权限' if restricted_readonly else filesystem['error'] or '原生数据目录文件系统不满足要求',
                         '核对 ext4 或 XFS ftype=1 支持及挂载状态', scope='native')
        host['data_mount'] = self.json_command('data-mount', '核实 /data 是否独立数据盘', ['findmnt','-J','-b','-T','/data','-o','TARGET,SOURCE,FSTYPE,SIZE,AVAIL'])
        fstab = self.run('fstab', '读取持久挂载记录（不挂载）', ['findmnt','--fstab','-n','-o','TARGET,SOURCE,FSTYPE'])
        host['fstab'] = fstab['stdout'].splitlines() if fstab['returncode'] == 0 else None
        host['prepared_storage']=self.prepared_storage(host)
        stat = os.statvfs('/'); host['root_available_bytes'] = stat.f_bavail*stat.f_frsize
        if host['root_available_bytes'] < 60*1024**3:
            self.finding('ROOT_SPACE', 'blocker', '系统盘剩余空间不足 60 GiB', '重新规划数据盘；不要自动删除现有数据')
        aliases = {}
        try:
            for link in Path('/dev/disk/by-id').iterdir():
                aliases.setdefault(str(link.resolve()), []).append(str(link))
        except OSError:
            self.finding('DISK_IDS_UNKNOWN', 'unknown', '无法读取磁盘稳定标识', '在真实主机权限上下文重跑 preflight')
        host['disk_ids'] = aliases
        host['two_tb_candidates'] = []
        disk_scope='data-disk' if host.get('prepared_storage') else 'nvme-pending'
        for disk in (host['blocks'] or {}).get('blockdevices', []):
            if disk.get('type') != 'disk' or not 1.8e12 <= int(disk.get('size') or 0) <= 2.3e12:
                continue
            entry = dict(disk=disk, stable_ids=aliases.get(disk['name'], []), volumes=[])
            for part in disk.get('children', []):
                volume = dict(device=part['name'], filesystem=part.get('fstype'), uuid=part.get('uuid'), mounts=[])
                for mount in part.get('mountpoints') or []:
                    if not mount: continue
                    d = self.directory(mount)
                    try:
                        st = os.statvfs(mount)
                        d.update(total_bytes=st.f_blocks*st.f_frsize, available_bytes=st.f_bavail*st.f_frsize,
                                 filesystem_used_bytes=(st.f_blocks-st.f_bfree)*st.f_frsize)
                    except OSError as e: d['space_error'] = safe_error(str(e))
                    volume['mounts'].append(d)
                entry['volumes'].append(volume)
                if part.get('fstype') not in ('ext4', 'xfs'):
                    self.finding('DATA_FILESYSTEM', 'blocker', f'{part["name"]} 是 {part.get("fstype") or "未知文件系统"}，不能直接用作本项目运行时数据盘',
                                 '先确认并保全现有文件，再另行确定 Linux 数据盘方案；本次不格式化或迁移', scope=disk_scope)
            if disk.get('children') or disk.get('fstype'):
                self.finding('DATA_DISK_OCCUPIED', 'warning', f'{disk["name"]} 已有分区/文件系统，不能当作空盘',
                             '继续使用已验证的 existing 挂载和软链接，不重新格式化' if host.get('prepared_storage') else '保持现状；数据用途和后续准备方案需先确定', scope=disk_scope)
            if disk.get('tran') == 'usb':
                self.finding('USB_DATA_DISK', 'warning', f'{disk["name"]} 通过 USB 接入，设备名可能随重连变化',
                             '通过序列号/稳定标识确认设备；正式使用前核实连接稳定性与掉电恢复', scope=disk_scope)
            host['two_tb_candidates'].append(entry)
        if not host['two_tb_candidates']:
            self.finding('TWO_TB_NOT_FOUND', 'unknown', '未发现约 2 TB 整盘候选', '核对连接、设备型号和实际容量，不猜测 /dev/nvme 名称', scope=disk_scope)
        mounts = (host['data_mount'] or {}).get('filesystems', [])
        if not host.get('prepared_storage') and (not mounts or mounts[0].get('target') != '/data' or not host['fstab'] or not any(line.split()[0] == '/data' for line in host['fstab'])):
            self.finding('DATA_MOUNT_PENDING', 'blocker', '/data 尚未证明为有持久挂载配置的独立 Linux 数据盘',
                         '保留 /data 中已有文件，后续单独确定迁移与挂载方案，再复检', scope=disk_scope)
        host['addresses'] = self.json_command('addresses', '读取网卡与 IPv4 地址', ['ip','-j','-4','addr','show'])
        host['routes'] = self.json_command('routes', '读取 IPv4 路由', ['ip','-j','-4','route','show'])
        host['suggested_ip'] = select_ip(host['addresses'] or [], host['routes'] or [])
        if not host['suggested_ip']:
            self.finding('NODE_IP_UNKNOWN', 'unknown', '无法确定本机部署 IP', '重跑具有 netlink 读取权限的预检；不会生成猜测地址配置')
        for interface in host['addresses'] or []:
            for addr in interface.get('addr_info', []):
                if addr.get('local') == host['suggested_ip'] and addr.get('dynamic'):
                    self.finding('DYNAMIC_IP', 'warning', f'{host["suggested_ip"]} 当前为动态地址（{interface["ifname"]}）', '安装前确定静态地址或 DHCP 固定租约，并复核选定 IP')
            if interface['ifname'] == 'Meta':
                self.finding('TUN_INTERFACE', 'warning', '检测到 Meta 隧道网卡，需排除代理路由对集群通信的影响', '在计划中固定业务网卡；验收 DNS、镜像域名及 Pod/Service 路由')
        for route in host['routes'] or []:
            if route.get('dst', 'default') == 'default': continue
            try:
                net=ipaddress.ip_network(route['dst'], strict=False)
                if any(net.overlaps(ipaddress.ip_network(c)) for c in ('10.233.64.0/18','10.233.0.0/18')):
                    self.finding('CIDR_OVERLAP', 'blocker', '现场路由与计划 Pod/Service 网段重叠', '先更改集群网段并重新预检')
            except ValueError: pass
        services=self.run('services','读取运行时、SSH、时间和 NFS 服务状态',
            ['systemctl','show','docker.service','docker.socket','containerd','chrony','chronyd','systemd-timesyncd','nfs-server','ssh',
             '--property=Id,LoadState,ActiveState,SubState,FragmentPath','--no-pager'])
        host['services'] = parse_services(services['stdout']) if services['returncode'] == 0 else None
        if host['services'] is None:
            self.finding('SERVICES_UNKNOWN','unknown','无法读取 systemd 服务状态','在主机上下文重新只读检测，不能将访问失败视为服务不存在')
        for service in host['services'] or []:
            if service.get('Id') in ('docker.service','containerd.service') and service.get('ActiveState') == 'active':
                self.finding('EXISTING_RUNTIME','blocker',service['Id']+' 已运行，首装保护会拒绝接管',
                             '先核实数据和业务用途，确定隔离环境或单独迁移/兼容方案；添加新盘不会解除此阻塞')
        paths=['/var/lib/docker','/var/lib/containerd','/var/lib/kubelet','/var/lib/etcd','/etc/kubernetes','/data']
        host['directories'] = [self.directory(p) for p in paths]
        spec=importlib.util.spec_from_file_location('runtime_audit',self.root/'lib/runtime-audit.py')
        runtime_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime_module)
        host['runtime_presence']=self.json_command('runtime-presence','核实运行时二进制、进程、socket 和遗留配置',
            [sys.executable,'-c',runtime_module.PRESENCE],privileged=True)
        docker_absent=runtime_module.absence_verified('docker',host['runtime_presence'],host['services'],host['directories'])
        docker_format = '{"root":{{json .DockerRootDir}},"server_version":{{json .ServerVersion}},"driver":{{json .Driver}},"containers":{{json .Containers}},"running":{{json .ContainersRunning}},"images":{{json .Images}}}'
        host['docker'] = None if docker_absent else self.json_command('docker','读取 Docker daemon 数据根目录与数量',
            ['docker','--host','unix:///var/run/docker.sock','info','--format',docker_format],privileged=True)
        if docker_absent:
            host['docker_status']='not_installed'
        elif host['docker'] is None or not host['docker'].get('server_version'):
            host['docker'] = None
            self.finding('DOCKER_DATA_UNKNOWN','unknown','Docker daemon 未授权或不可访问，容器/镜像/卷情况未核实','以有权限账号重跑只读预检，不应按空 Docker 环境处理')
        else:
            result=self.run('docker-usage','读取 Docker 镜像、容器及卷用量',
                ['docker','--host','unix:///var/run/docker.sock','system','df','--format','{{json .}}'],privileged=True)
            try: host['docker']['usage']=[json.loads(l) for l in result['stdout'].splitlines()] if result['returncode']==0 else None
            except ValueError: host['docker']['usage']=None
            if not host['docker']['usage']:
                self.finding('DOCKER_USAGE_UNKNOWN','unknown','Docker 容器/镜像/卷用量尚未完整核实', '查看 docker-usage 日志，以有权限账号只读复检')
        if host['docker'] and host['docker'].get('root') and host['docker']['root'] not in paths:
            host['directories'].append(self.directory(host['docker']['root']))
        for d in host['directories']:
            if d.get('symlink') and d['path'] in ('/var/lib/docker','/var/lib/containerd','/var/lib/kubelet'):
                self.finding('NATIVE_DATA_SYMLINK','blocker',d['path']+' 已是软链接，native 首装会拒绝',
                             '使用通过复核的 existing 独立数据盘配置',scope='native')
            if d.get('top_level_entries',0)>0 and d['path'] != '/data':
                self.finding('EXISTING_COMPONENT_DATA','blocker',d['path']+' 已有内容','保留现场数据；首装不会自动迁移、覆盖或清理')
            elif d.get('content_status') == 'unknown':
                self.finding('DIRECTORY_UNREADABLE','unknown',d['path']+' 内容/容量未完整核实', '以 root 只读重跑预检，不得推断为空目录')
        # Only the read-only inventory module is loaded. It uses this audit's
        # command recorder and cannot imply permission to adopt existing data.
        try:
            host['runtime']=runtime_module.collect(self.run,self.finding,docker_info=host['docker'],directories=host['directories'],
                                                   presence=host['runtime_presence'],services=host['services'])
            write_json(self.out/'runtime-report.json',host['runtime'])
            render_runtime_report(host['runtime'],self.out)
        except (OSError,ValueError,KeyError,TypeError) as e:
            host['runtime']=None
            self.finding('RUNTIME_INVENTORY_UNKNOWN','unknown','运行时详细清单未完整生成：'+safe_error(str(e)),
                         '查看 runtime 检测日志；不能按空运行时处理')
        time_result=self.run('time-sync','读取当前时间同步状态', ['timedatectl','show','--property=NTPSynchronized','--property=NTP','--property=Timezone','--no-pager'])
        time_fields={line.split('=',1)[0] for line in time_result['stdout'].splitlines() if '=' in line}
        host['time_sync'] = time_result['stdout'].splitlines() if time_result['returncode']==0 and {'NTPSynchronized','NTP','Timezone'}<=time_fields else None
        if host['time_sync'] is None:
            self.events[-1]['status']='unknown'
            if not self.events[-1]['error']:self.events[-1]['error']='时间同步属性缺失；不能将空输出判为已同步'
            write_json(self.out/'checks.json',self.events)
            self.finding('TIME_STATUS_UNKNOWN','unknown','当前时间同步状态未核实','查看 time-sync.stderr 后重跑')
        ports=self.run('ports','检查安装端口占用', ['ss','-H','-lnt'])
        host['occupied_install_ports'] = sorted(set(re.findall(r':(443|6443|2379|2380|10250)\s',ports['stdout']))) if ports['returncode']==0 else None
        if host['occupied_install_ports']:
            self.finding('INSTALL_PORTS','blocker','安装端口已占用: '+','.join(host['occupied_install_ports']), '核实占用服务用途，不能直接停止现有服务')
        if host['occupied_install_ports'] is None:
            self.finding('PORT_STATUS_UNKNOWN','unknown','无法核实安装端口占用','查看 ports.stderr 后重跑')
        host['tools'] = {c:shutil.which(c) for c in ('python3','jq','ssh','sshpass','flock','chronyc','chronyd','exportfs','mount.nfs','7z')}
        self.finding('NTP_PLAN','warning','草案按完全离线场景将 node1 设为本地 chrony 时间源；当前尚未变更服务',
                     '安装前核对机器时间；本地时间源只保证集群相对一致，不保证真实时间准确。若有现场 NTP，请改为 external 并填写 NTP_SERVERS')
        return host


def select_ip(addresses, routes):
    defaults=sorted((r for r in routes if r.get('dst')=='default'),key=lambda r:r.get('metric',0))
    for route in defaults:
        if re.match(r'^(lo$|docker|veth|br-|cni|flannel|virbr|tun|tap|wg|tailscale|meta$)', route.get('dev',''), re.I):
            continue
        for interface in addresses:
            if interface.get('ifname') != route.get('dev'): continue
            ips=[a['local'] for a in interface.get('addr_info',[]) if a.get('scope')=='global' and a.get('family')=='inet']
            if route.get('prefsrc') in ips:return route['prefsrc']
            if len(ips)==1:return ips[0]
    return None


def parse_services(text):
    result=[]
    for block in text.strip().split('\n\n'):
        values=dict(line.split('=',1) for line in block.splitlines() if '=' in line)
        if values.get('Id'):result.append(values)
    return result


def prepared_link_root(links):
    expected={'/var/lib/docker':'docker','/var/lib/containerd':'containerd',
              '/var/lib/kubelet':'kubelet','/var/lib/harbor/data':'harbor'}
    if set(links)!=set(expected):return None
    parents=set()
    for source,suffix in expected.items():
        path=Path(links[source])
        if not path.is_absolute() or path.name!=suffix or any(c.isspace() for c in str(path)) or '..' in path.parts:return None
        parents.add(str(path.parent))
    return next(iter(parents)) if len(parents)==1 and '/' not in parents else None


def persistent_mount_matches(mount, fstab):
    if mount.get('target') in (None,'/') or mount.get('fstype') not in ('ext4','xfs') or 'ro' in (mount.get('options') or '').split(','):
        return False
    entries=[line.split() for line in fstab or [] if len(line.split())==3 and line.split()[0]==mount['target']]
    if len(entries)!=1:return False
    target,source,filesystem=entries[0]
    return filesystem==mount['fstype'] and (source==mount.get('source') or bool(mount.get('uuid')) and source=='UUID='+mount['uuid'])


def deployment_modes(host):
    return ('native','data-disk') if host.get('prepared_storage') else ('native','nvme-pending')


def assess_runtime_compatibility(audit, host, kubernetes):
    defaults=audit.root/'kk-project/roles/defaults/vars'/('.'.join(kubernetes.split('.')[:2])+'.yaml')
    try:
        text=defaults.read_text()
        expected={key:re.search(r'^\s*'+key+r':\s*[\"\']?([^\s\"\']+)',text,re.M).group(1)
                  for key in ('docker_version','containerd_version','runc_version')}
    except (OSError,AttributeError) as error:
        audit.finding('RUNTIME_TARGET_UNKNOWN','unknown','无法读取目标运行时版本：'+safe_error(str(error)),
                      '检查随包版本默认值，禁止猜测或直接复用现有运行时')
        return
    host['target_runtime_versions']=expected
    installed=(host.get('docker') or {}).get('server_version')
    if installed and installed.lstrip('v')!=expected['docker_version'].lstrip('v'):
        audit.finding('RUNTIME_VERSION_MISMATCH','blocker',
                      '现有 Docker '+installed+' 与项目目标 '+expected['docker_version']+' 不一致；不能视为无变更复用',
                      '保留现有运行时。KubeKey 安装路径可能替换二进制、重写配置并重启服务；先选择隔离环境或完成专门兼容设计')
    for instance in ((host.get('runtime') or {}).get('containerd') or {}).get('instances') or []:
        matched=re.search(r'Server:\s*\n\s*Version:\s*(\S+)',instance.get('version') or '')
        if matched:
            instance['server_version']=matched.group(1)
            if matched.group(1).lstrip('v')!=expected['containerd_version'].lstrip('v'):
                audit.finding('CONTAINERD_VERSION_MISMATCH','blocker',
                              '现有 containerd 服务端 '+matched.group(1)+' 与项目目标 '+expected['containerd_version']+' 不一致：'+instance['socket'],
                              '先明确共享 Docker image store 的数据保全与兼容方案；不覆盖配置、替换二进制或重启服务')


def write_configs(audit, host, kubernetes):
    config_ip=host.get('planned_ip') or host['suggested_ip']
    if not config_ip or (host['os_id'],host['os_version'],host['architecture']) != ('ubuntu','24.04','x86_64'):
        return []
    expected=''
    for line in (audit.root/'artifact/SHA256SUMS').read_text().splitlines():
        fields=line.split()
        if len(fields)==2 and fields[1].lstrip('./')=='kubekey-artifact.tgz':expected=fields[0]
    base=dict(COMPONENTS='all',KUBE_VERSION=kubernetes,KK_VERSION='v4.0.10',ENDPOINT_TYPE='local',ENDPOINT_ADDRESS='',
              ENDPOINT_PORT='6443',K8S_DOMAIN='lb.rise.io',POD_CIDR='10.233.64.0/18',SERVICE_CIDR='10.233.0.0/18',
              REGISTRY_MODE='harbor',HARBOR_DOMAIN='harbor.rise.io',HARBOR_PORT='443',HARBOR_HTTP='false',
              HARBOR_SOURCE_DIR='/var/lib/harbor/data',HARBOR_VIP='',LOCAL_STORAGE='true',LOCAL_PATH='/data/local-pv',
              NFS_MODE='none',NFS_NODE='',NFS_SERVER='',NFS_PATH='/data/nfs',NTP_MODE='node',NTP_SERVERS='',
              NTP_NODE='node1',NTP_ALLOW_LOCAL='true',SSH_AUTH_MODE='key',SSH_KEY='/root/.ssh/rise_deploy',
              SSH_PARALLEL='1',MIN_ROOT_FREE_GIB='60',DEPS_MODE='iso',
              ARTIFACT_FILE=str(audit.root/'artifact/kubekey-artifact.tgz'),ARTIFACT_SHA256=expected)
    outputs=[]
    for mode in deployment_modes(host):
        data_root=host['prepared_storage']['path'] if mode=='data-disk' else '/data'
        config=base.copy();config['CLUSTER_NAME']='local-aio-'+mode
        config['STATE_DIR']=str(audit.root/'state'/config['CLUSTER_NAME'])
        config['WORK_DIR']=data_root+'/rise-deploy';config['ALLOW_ROOT_WORKDIR']='true' if mode=='native' else 'false'
        config['LOCAL_PATH']=data_root+'/local-pv';config['NFS_PATH']=data_root+'/nfs'
        config['NODES']=f'node1|{config_ip}|{config_ip}|root|22|amd64|ubuntu-24.04-debs|control_plane,worker,registry|local|{data_root}|'+('native' if mode=='native' else 'existing')+'||'
        p=audit.out/('all-in-one-'+mode+'.env')
        comments='# 本机只读预检生成的配置草案；执行前核对阻塞清单和阶段验收要求。\n# 不含密码；没有格式化设备配置。node1 共置 master/worker/Harbor，local 连接不需要 SSH 密钥。\n# 完全离线假设：node1 为本地时间源（不保证真实时间准确），NFS 不启用；地址固定策略待确认。\n'
        docker=host.get('docker')
        if docker:
            comments+=f'# 现场 Docker {docker.get("server_version","未知")}：容器 {docker.get("containers","未知")}，运行中 {docker.get("running","未知")}，镜像 {docker.get("images","未知")}；不自动接管或迁移现有运行时。\n'
        if config_ip!=host['suggested_ip']:comments+='# 节点地址为显式传入的规划值，本次未完成现场验证，安装前必须复检。\n'
        if mode=='data-disk':comments+='# 已只读核验独立数据盘、持久挂载和组件软链接：'+data_root+'；不包含格式化步骤。\n'
        elif mode!='native':comments+='# 独立数据盘尚未完成挂载/软链接复核；先确认现有数据与 Linux 文件系统，再使用此草案。\n'
        p.write_text(comments+''.join(k+'='+shlex.quote(str(v))+'\n' for k,v in config.items()));p.chmod(0o600)
        outputs.append(p.name)
        result=audit.run('plan-'+mode,'生成 '+mode+' 静态部署计划', ['bash',str(audit.root/'deploy.sh'),'plan','--env',str(p)],timeout=30)
        blockers=[f for f in audit.findings if f['level'] in ('blocker','unknown') and f.get('scope','all') in ('all',mode)]
        observed='本轮现场前置条件（只读快照，执行前需重检）\n'
        if blockers:
            observed+='状态：阻塞或尚未核实，不能开始安装。\n'+''.join('- '+f['code']+'：'+f['message']+'；'+f['action']+'\n' for f in blockers)
        else:observed+='未发现该方案的已知阻塞；仍需完成正式阶段验收。\n'
        observed+='保留现有容器、镜像、卷、bind 源目录和运行时数据；不把 Docker Reclaimable 当作删除授权。\n\n'
        runtime=host.get('runtime') or {}
        preserve=sorted({item['path'] for section in ('docker','containerd')
                         for item in (runtime.get(section) or {}).get('storage_paths') or [] if item.get('path')})
        if preserve:observed+='本轮发现的具体保留路径：\n'+''.join('  '+path+'\n' for path in preserve)+'\n'
        if host.get('target_runtime_versions'):
            observed+='随包目标运行时版本：'+json.dumps(host['target_runtime_versions'],ensure_ascii=False)+'\n\n'
        (audit.out/('plan-'+mode+'.txt')).write_text(observed+result['stdout']+result['error'])
        if result['returncode']!=0:audit.finding('CONFIG_INVALID','blocker',mode+' 配置未通过项目校验','按日志修复配置，禁止继续安装')
    return outputs


def offline_findings(audit, offline, kubernetes):
    """Keep media health, current host resolution and fresh-OS closure separate."""
    if not offline:
        audit.finding('OFFLINE_UNCHECKED','unknown','离线依赖闭包尚未核实',
                      '运行完整 preflight 或合并对应的离线审计报告')
        return
    if offline.get('root') != str(audit.root) or offline.get('kubernetes') != kubernetes or offline.get('architecture') != 'amd64':
        audit.finding('OFFLINE_SCOPE_MISMATCH', 'unknown', '离线证据与当前项目/版本/架构不匹配', '重新执行完整 preflight')
    for check in offline.get('blockers', []):
        audit.finding('OFFLINE:'+check['code'], 'blocker', safe_error(str(check.get('detail', '离线检查未通过'))),
                      '参看离线报告及对应日志，补齐本地制品后重新审计')
    if offline.get('status') not in ('passed', 'checked_with_limits') and not offline.get('blockers'):
        audit.finding('OFFLINE_STATUS_UNKNOWN', 'unknown', '离线审计未给出可判读的通过状态', '重新执行离线预检')
    sims = offline.get('simulations', {})
    for key in ('node-base', 'node-nfs', 'bootstrap', 'combined'):
        if sims.get(key, {}).get('status') != 'passed':
            audit.finding('APT_'+key.upper(), 'blocker', key+' 本机本地依赖解析未通过',
                          '查看离线 apt-'+key+'/simulate.log；禁止安装时回退到公网源')
    missing = [p['package'] for p in offline.get('packages', []) if not p.get('on_media')]
    if missing:
        audit.finding('BASE_OS_DEPENDENCY', 'warning', '介质未提供 '+', '.join(missing)+'；当前模拟依赖本机已有安装',
                      '新机器须使用匹配的 Ubuntu 基础环境逐机复检；不能宣称空白环境全部依赖已闭包')
    if any(v.get('would_remove') for k,v in sims.items() if not k.startswith('empty-state')):
        removals = sorted(set(r for k,v in sims.items() if not k.startswith('empty-state') for r in v.get('would_remove', [])))
        audit.finding('APT_SERVICE_CHANGE', 'warning', 'APT 模拟显示安装时会移除：'+'; '.join(removals),
                      '计划从 systemd-timesyncd 切换到 chrony；实际执行后必须经过 services-init/services-verify')
    for check in offline.get('warnings', []):
        if check.get('code', '').startswith('sha256:'):
            audit.finding('MEDIA_OPTIONAL_MISSING', 'warning', check['code']+'：'+str(check.get('detail', '')),
                          '本次选定流程不使用该工具，但发行清单尚不完整，重新交付前应补齐')


def load_offline(path):
    data=json.loads(path.read_text())
    if not isinstance(data, dict): raise ValueError('离线报告顶层必须为对象')
    if not isinstance(data.get('status'),str): raise ValueError('离线报告缺少有效 status')
    for key in ('checks','blockers','warnings','packages'):
        if not isinstance(data.get(key),list) or any(not isinstance(item,dict) for item in data[key]):
            raise ValueError('离线报告 '+key+' 格式错误')
    for item in data['checks']+data['blockers']+data['warnings']:
        if not all(isinstance(item.get(k),str) for k in ('code','status')):
            raise ValueError('离线检查缺少 code/status')
    for item in data['packages']:
        if not isinstance(item.get('package'),str) or not isinstance(item.get('on_media'),bool):
            raise ValueError('离线软件包信息格式错误')
        if item.get('installed_version') is not None and not isinstance(item['installed_version'],str):
            raise ValueError('已装软件包版本格式错误')
    sims=data.get('simulations')
    if not isinstance(sims,dict) or any(not isinstance(v,dict) for v in sims.values()):
        raise ValueError('离线模拟结果格式错误')
    for sim in sims.values():
        if not isinstance(sim.get('status'),str): raise ValueError('离线模拟缺少有效 status')
        for key in ('would_install','would_remove'):
            values=sim.get(key,[])
            if not isinstance(values,list) or any(not isinstance(v,str) for v in values):
                raise ValueError('离线模拟 '+key+' 格式错误')
    return data


def verify_reused_evidence(audit, offline):
    """Fast freshness check, not a substitute for a new SHA scan of media."""
    try:
        inputs=offline['evidence_inputs']; state=inputs['dpkg_status']; media=inputs['media']
        if not isinstance(media,list) or not media: raise ValueError('缺少介质指纹')
        if state['path']!='/var/lib/dpkg/status': raise ValueError('dpkg 状态路径不符')
        for item in [state]+media:
            path=Path(item['path'])
            if item is not state: path.resolve().relative_to(audit.root.resolve())
            st=path.stat()
            if st.st_size!=item['size'] or st.st_mtime_ns!=item['mtime_ns']:
                raise ValueError(str(path)+' 大小或修改时间已变化')
        digest=hashlib.sha256(Path(state['path']).read_bytes()).hexdigest()
        if digest!=state['sha256']: raise ValueError('系统 dpkg 状态已变化')
    except (KeyError,TypeError,ValueError,OSError) as e:
        audit.finding('OFFLINE_EVIDENCE_STALE','unknown','复用证据无法证明仍适用于当前输入：'+safe_error(str(e)),
                      '重新执行完整 preflight；旧报告仅作历史参考')


def outcome(findings, mode):
    return ('blocked_or_incomplete' if any(f['level'] in ('blocker','unknown') and
            f.get('scope','all') in ('all',mode) for f in findings) else 'checked_with_limits')


def render_runtime_report(runtime, out):
    def cell(value):
        return str(value if value is not None else '未核实').replace('|','/').replace('\n',' ')
    def size(value):
        return f'{value/1024**3:.3f} GiB ({value} B)' if isinstance(value,(int,float)) else '未核实'
    def table(headers,rows):
        return ['| '+' | '.join(headers)+' |','| '+' | '.join('---' for _ in headers)+' |']+[
            '| '+' | '.join(cell(v) for v in row)+' |' for row in rows]
    docker=runtime.get('docker') or {}
    absent_text='未安装：已核实无运行时二进制/活动服务/进程/socket/遗留配置，默认数据路径不存在或可读且为空；本节清单不适用。'
    lines=['# Docker/containerd 只读数据清单','',
           '只读取元数据与目录占用；没有启动、停止、导出、导入、删除容器或镜像，没有挂载、卸载或清理数据。',
           '不导出容器环境变量、启动参数、Labels、卷驱动 Options 或仓库凭据。目录扫描及 daemon 清单不是原子快照，可能随外部业务变化。','',
           '## Docker 容器','']
    containers=docker.get('containers')
    if docker.get('status')=='not_installed':lines+=[absent_text]
    elif containers is None:lines+=['未完整核实，不能按 0 个处理。']
    else:
        lines+=['数量：'+str(len(containers))+'。','']
        lines+=table(['名称','ID','镜像','状态','退出码','可写层'],[
            [c.get('name'),c.get('id'),c.get('image_ref'),c.get('state'),c.get('exit_code'),size(c.get('size_rw'))] for c in containers])
        mounts=[]
        for c in containers:
            for v in c.get('mounts') or []:
                mounts.append([c.get('name'),v.get('type',v.get('Type')),v.get('source',v.get('Source')),
                               v.get('destination',v.get('Destination')),v.get('rw',v.get('RW'))])
        lines+=['','### 容器挂载与宿主机数据','']+table(['容器','类型','宿主机源','容器目标','可写'],mounts)
        lines+=['','bind 源目录不计入 Docker 本地卷数量；即使容器停止也必须保留源目录。']
    lines+=['','## Docker 镜像','']
    images=docker.get('images')
    if docker.get('status')=='not_installed':lines+=[absent_text]
    elif images is None:lines+=['未完整核实，不能按 0 个处理。']
    else:
        lines+=['数量：'+str(len(images))+'。','']+table(['ID','引用','摘要','逻辑大小'],[
            [i.get('id'),', '.join(i.get('tags') or []),', '.join(i.get('digests') or []),size(i.get('size_bytes'))] for i in images])
    lines+=['','## Docker 本地卷','']
    volumes=docker.get('volumes')
    if docker.get('status')=='not_installed':lines+=[absent_text]
    elif volumes is None:lines+=['未完整核实，不能按 0 个处理。']
    else:lines+=['数量：'+str(len(volumes))+'。','']+table(['卷名','驱动','挂载路径','范围'],[
        [v.get('name'),v.get('driver'),v.get('mountpoint'),v.get('scope')] for v in volumes])
    lines+=['','## 占用统计与共享存储','',
            'Docker 镜像、BuildKit 构建缓存、containerd content/snapshot 可能共享数据；不得简单相加。Reclaimable 是 daemon 估计，不代表已授权删除。','',
            'Docker system df：','',*table(['类型','数量','活动项','逻辑大小','报告可回收量'],[
                [u.get('Type'),u.get('TotalCount'),u.get('Active'),u.get('Size'),u.get('Reclaimable')] for u in docker.get('usage') or []])]
    paths=[]
    for section in ('docker','containerd'):
        for item in (runtime.get(section) or {}).get('storage_paths') or []:
            paths.append([section,item.get('path'),size(item.get('bytes')),item.get('status','见 JSON')])
    lines+=['','目录占用（du 分配字节；父子目录不得再次相加）：','']+table(['归属','路径','占用','状态'],paths)
    lines+=['','## containerd 实例与命名空间','',
            'containerd 没有 Docker 式的独立命名卷目录。挂载与数据按 Docker Mounts、容器元数据和 snapshotter 分开核实。已停止的 Docker 容器可以只保留在 Docker 元数据中，不一定出现在 ctr containers list 中。','']
    if (runtime.get('containerd') or {}).get('status')=='not_installed':lines+=[absent_text,'']
    for instance in (runtime.get('containerd') or {}).get('instances') or []:
        lines+=['实例：`'+cell(instance.get('socket'))+'`；服务端：`'+cell(instance.get('server_version'))+'`；root：`'+cell(instance.get('root'))+'`；state：`'+cell(instance.get('state'))+'`。','']
        namespaces=instance.get('namespaces')
        if namespaces is None:lines+=['命名空间尚未核实。'];continue
        for ns in namespaces:
            lines+=['### '+cell(ns.get('name')),'']
            for key,label in [('containers','容器'),('images','镜像引用'),('tasks','任务'),('snapshots','快照')]:
                entries=ns.get(key)
                if key=='snapshots' and entries is not None:
                    count=sum(len(group.get('entries') or []) for group in entries)
                    incomplete=any(group.get('entries') is None for group in entries)
                    lines+=[label+'：'+str(count)+' 个已枚举；'+str(len(entries))+' 个 snapshotter'+('，部分未核实' if incomplete else '')+'。']
                else:lines+=[label+'：'+('未核实' if entries is None else str(len(entries)))+'。']
                if entries and key in ('containers','images','tasks'):
                    lines+=['```json',json.dumps(entries,ensure_ascii=False,indent=2),'```']
            lines+=['快照具体条目与 snapshotter 见 runtime-report.json。','']
    lines+=['','## 验证边界','']+['- '+str(v) for v in runtime.get('limitations') or []]
    text='\n'.join(lines)+'\n';(out/'runtime-report.md').write_text(text)
    (out/'runtime-report.html').write_text('<!doctype html><meta charset="utf-8"><title>运行时数据清单</title><pre style="white-space:pre-wrap;overflow-wrap:anywhere">'+html.escape(text)+'</pre>')


def offline_table(offline):
    if not offline: return ['未执行离线审计。']
    lines = ['| 检查范围 | 结果 | 证据 / 限制 |', '| --- | --- | --- |']
    for label, key in [('节点前置依赖', 'node-base'),('节点 + 可选 NFS 服务端', 'node-nfs'),
                       ('控制端 + 密码 SSH 工具', 'bootstrap'),('组合依赖', 'combined'),
                       ('空 dpkg 状态诊断', 'empty-state'),('空状态下介质已有包的依赖', 'empty-state-present-packages')]:
        sim = offline.get('simulations', {}).get(key, {})
        lines.append('| '+label+' | '+sim.get('status','未核实')+' | '+
                     ('拟安装 '+str(len(sim.get('would_install', [])))+' 个包；' if sim.get('status')=='passed' else '')+
                     '`apt-'+key+'/simulate.log` |')
    for check in offline.get('checks', []):
        if check['code'] in ('selected_artifact_members', 'package_files:iso-repo', 'package_files:bootstrap-repo') or check['code'].startswith('oci'):
            lines.append('| '+check['code']+' | '+check['status']+' | '+str(check['detail']).replace('|','/')+' |')
    lines += ['', 'APT 仅使用本地 file: 包源及当前系统 dpkg 状态，不执行安装、维护脚本或服务启动。空 dpkg 状态测试比全新 Ubuntu 基础系统更严格，其失败说明介质不含完整基础 OS，不能直接等同于所有新 Ubuntu 机器均不可安装。', '',
              '| 目标包 | 本地介质 | 本机已装版本 |', '| --- | --- | --- |']
    lines += ['| '+p['package']+' | '+('有' if p['on_media'] else '无，依赖基础系统')+' | '+(p.get('installed_version') or '未安装')+' |' for p in offline.get('packages', [])]
    return lines


def env_stem(name):
    """Example env name without the all-in-one- prefix and .env suffix.

    str.removeprefix/removesuffix need Python 3.9; the Web/preflight host is
    documented for Python 3.8, so keep this compatible with that baseline.
    """
    stem = name[len('all-in-one-'):] if name.startswith('all-in-one-') else name
    return stem[:-4] if stem.endswith('.env') else stem


def render_report(data, out):
    h=data['host']
    config_links = ['- 配置：['+name+']('+name+')；计划：[plan-'+env_stem(name)+'.txt](plan-'+env_stem(name)+'.txt)' for name in data['configurations']]
    lines=['# 本机 all in one 只读预检','',f'检查时间：{data["generated_at"]}',
        '',f'结论：{data["status"]}。本次只读取主机与介质，写入本目录的报告/配置；未安装、挂载、格式化或清理数据。',
        '',f'系统：{h["os"]}；内核：{h["kernel"]}；CPU：{h["cpu_threads"]} 线程；内存：{h["memory_bytes"]/1024**3:.1f} GiB。',
        f'实测部署 IP：{h["suggested_ip"] or "未核实"}；规划 IP：{h.get("planned_ip") or h["suggested_ip"] or "未设置"}；系统盘可用：{h["root_available_bytes"]/1024**3:.1f} GiB。','',
        '## 磁盘与现有数据','', '| 整盘 | 型号 | 容量 | 接入 | 分区文件系统 |', '| --- | --- | --- | --- | --- |']
    for disk in (h['blocks'] or {}).get('blockdevices', []):
        if disk.get('type')=='disk':
            filesystems=', '.join(sorted(set(p.get('fstype') or '未识别' for p in disk.get('children', []))))
            lines += [f'| {disk["name"]} | {disk.get("model")} | {disk["size"]/1e12:.3f} TB | {disk.get("tran")} | {filesystems} |']
    lines += ['', '以下仅记录容量、顶层条目数和文件系统，不读取用户文件内容。','']
    for entry in h['two_tb_candidates']:
        d=entry['disk'];lines += [f'- 约 2 TB 候选：`{d["name"]}`，{d["model"]}，序列号 `{d["serial"]}`，接入方式 {d.get("tran")}，容量 {d["size"]/1e12:.3f} TB。']
        for v in entry['volumes']:
            lines += [f'  - 分区 `{v["device"]}`：{v["filesystem"]}，UUID `{v["uuid"]}`。']
            for m in v['mounts']:
                used=f'{m["filesystem_used_bytes"]/1024**3:.2f} GiB' if 'filesystem_used_bytes' in m else '未核实'
                lines += [f'  - 已挂载 `{m["path"]}`；顶层条目 {m.get("top_level_entries","未核实")}；文件系统已用 {used}（不是可删除数据判断）。']
        lines += ['  - 稳定路径标识：'+(', '.join('`'+p+'`' for p in entry['stable_ids']) or '当前上下文无法读取；请按上面的序列号和 UUID 核对设备')]
    lines += ['', 'Docker daemon：'+(json.dumps(h['docker'],ensure_ascii=False) if h['docker'] else '已核实未安装；容器/镜像/卷清单不适用。' if h.get('docker_status')=='not_installed' else '未获完整读取权限；数量和用量未知，不能当作零。'),'',
              '| 目录 | 存在 | 顶层条目 | 总量 |','| --- | --- | --- | --- |']
    for d in h['directories']:
        lines += ['| '+d['path']+' | '+('未核实' if d['exists'] is None else str(d['exists']))+' | '+str(d.get('top_level_entries','不适用' if d['exists'] is False else '未核实'))+' | '+(f'{d["bytes"]/1024**3:.2f} GiB' if 'bytes' in d else '不适用' if d['exists'] is False else '未核实')+' |']
    if h.get('runtime'):
        lines+=['','详细容器、镜像、卷、bind 数据目录和 containerd 命名空间清单：[运行时只读清单](runtime-report.md) / [结构化证据](runtime-report.json)。','',
                '权限核实成功不会取消现有运行时保护。停止的容器、未运行的任务、0 个命名卷都不等同于没有现有业务数据。']
    lines += ['', '## 检测结论与安装前阻塞','', '方案状态：'+json.dumps(data['mode_status'], ensure_ascii=False)+'。选定方案：'+data.get('selected_mode','native')+'；`all` 表示共同约束，其他范围仅适用于对应方案。', '',
              '| 级别 | 适用方案 | 编号 | 发现 | 下一步 |','| --- | --- | --- | --- | --- |']
    for f in data['findings']:lines += ['| '+' | '.join(str(f[k]).replace('|','/').replace('\n',' ') for k in ('level','scope','code','message','action'))+' |']
    lines += ['', '## 配置与后续部署顺序','',
              ('主方案为 data-disk：已只读核验 '+h['prepared_storage']['path']+' 独立挂载、持久配置和组件软链接；native 配置因现有软链接而不可用。' if h.get('prepared_storage') else '主方案为 native：保留系统盘原生目录，不选格式化设备。NVMe pending 文件描述待核验的独立 Linux 数据盘方案。两种方案都不能绕过现有运行时归属保护。'),'',
              '`access → prepare → deps → services-init → services-verify → harbor-install → harbor-projects → images-import → images-verify → k8s-install → node-images-verify → ledger`','',
              '先解决报告中的 blocker 和 unknown，再重新 preflight。NFS 默认不启用；离线审计另外检查可选 NFS 服务端包。',
              '草案：node1 同时承担 master、worker、Harbor；本地连接不需要 SSH 免密；单节点不启用 HA。NFS 不启用，使用本地卷。NTP 按完全离线场景明确配置 node1 本地时间源，实际执行会由 chrony 接管，需先核对系统时间；若存在现场 NTP 则改为 external。','',
              ('已准备组件链接：'+json.dumps(h['prepared_storage']['links'],ensure_ascii=False)+'；保留 /data 下其他路径，后续准备阶段应继续使用 existing 模式。' if h.get('prepared_storage') else '原生方案不为 Docker/containerd 建软链接；独立数据盘须核验 Linux 文件系统、fstab 持久化与已有文件，再准备组件目录；不得挂载遮蔽已有数据。'),'',
              *config_links, '',
              '## 离线依赖证据','',f'离线审计报告：{data.get("offline_report_path") or "未执行"}。',
              '文件存在、摘要正确、APT 依赖解析成功与真实安装成功是不同结论；镜像只做介质检查，未推送 Harbor 或通过 CRI 拉取。','',
              *offline_table(data.get('offline')), '', '## 检测进度与具体错误', '',
              '每项命令保存退出码、耗时、stdout/stderr 日志；完整记录见 checks.json。权限不足、失败和未检测项不会显示为通过。', '',
              '| 检查 | 状态 | 退出码 | 秒 | 错误 / 日志 |', '| --- | --- | --- | --- | --- |']
    for c in data['checks']:
        lines += ['| '+c['label']+' | '+c['status']+' | '+str(c['exit_code'])+' | '+str(c['elapsed_seconds'])+' | '+(c['error'] or c['stdout_log']).replace('|','/').replace('\n',' ')+' |']
    text='\n'.join(lines);(out/'preflight-report.md').write_text(text)
    (out/'preflight-report.html').write_text('<!doctype html><meta charset="utf-8"><title>本机只读预检</title><style>body{font:16px sans-serif;margin:28px}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style><pre>'+html.escape(text)+'</pre>')


def _kubernetes_versions(root):
    import re
    versions=[]
    for path in sorted((root / 'configs').glob('v*.yaml')):
        if not re.fullmatch(r'v\d+\.\d+\.\d+', path.stem):
            continue
        body=path.read_text(encoding='utf-8')
        match=re.search(r'^\s*kube_version:\s*["\']?(v\d+\.\d+\.\d+)', body, re.MULTILINE)
        if not match or match.group(1) != path.stem:
            raise ValueError('版本文件与 kube_version 不一致: '+path.name)
        versions.append(path.stem)
    if not versions:
        raise ValueError('configs/ 下没有可用的 Kubernetes 版本文件')
    return sorted(set(versions), key=lambda value: tuple(int(x) for x in re.findall(r'\d+', value)), reverse=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--kubernetes')
    parser.add_argument('--node-ip',type=ipaddress.IPv4Address,help='显式规划 IPv4；现场未核实则仅生成草案，不会消除网络阻塞')
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--host-only',action='store_true',help='仅主机检查；离线完整性标为未验证')
    modes.add_argument('--offline-report',type=Path,help='合并已有离线审计证据，保留原路径和时间，不宣称重新检测')
    args=parser.parse_args()
    try:
        versions=_kubernetes_versions(args.root)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.kubernetes is None:
        args.kubernetes=versions[0]
    elif args.kubernetes not in versions:
        parser.error('不支持的 Kubernetes 版本: '+args.kubernetes)
    os.umask(0o077)
    args.output=args.output.resolve();args.root=args.root.resolve()
    try: args.output.mkdir(parents=True,exist_ok=False)
    except OSError as e: parser.error('报告目录必须为可创建的新目录：'+str(e))
    a=Audit(args.root,args.output);offline=None;offline_path=None
    try: host=a.host()
    except (OSError,ValueError,KeyError,TypeError) as e:
        error=safe_error(str(e))
        a.finding('HOST_AUDIT_ERROR','unknown',error,'查看本目录日志，修复检测器后使用新目录重跑')
        write_json(args.output/'report.json',dict(status='audit_failed',findings=a.findings,checks=a.events))
        (args.output/'preflight-report.md').write_text('# 本机预检未完成\n\n检测器异常：'+error+'\n\n不能据此继续安装。已完成的检测日志见 checks.json。\n')
        print('[检测器失败] '+error+'；已保存部分报告至 '+str(args.output),file=sys.stderr)
        return 1
    host['planned_ip']=str(args.node_ip) if args.node_ip else host['suggested_ip']
    if args.node_ip and host['planned_ip']!=host['suggested_ip']:
        a.finding('PLANNED_IP_UNVERIFIED','unknown','配置使用显式规划地址 '+host['planned_ip']+'，本轮未证明它是可用部署地址',
                  '以有权限的终端核实该地址属于业务网卡，并固定静态地址或 DHCP 租约')
    if args.offline_report:
        offline_path=args.offline_report.resolve()
        try:
            offline=load_offline(offline_path)
            verify_reused_evidence(a,offline)
        except (OSError,ValueError) as e: a.finding('OFFLINE_REPORT_INVALID','unknown',safe_error(str(e)),'重跑完整预检')
        a.finding('OFFLINE_REPORT_REUSED','warning','合并已有离线审计证据，未重复扫描介质','参看原报告时间/范围；介质或系统包状态变化后须重新审计')
    elif not args.host_only:
        offline_dir=args.output/'offline'
        code=subprocess.call([sys.executable,str(args.root/'lib/offline-audit.py'),'--root',str(args.root),'--output',str(offline_dir),'--kubernetes',args.kubernetes])
        offline_path=offline_dir/'report.json'
        if offline_path.exists():
            try: offline=load_offline(offline_path)
            except (OSError,ValueError) as e: a.finding('OFFLINE_REPORT_INVALID','unknown',safe_error(str(e)),'重跑完整预检')
        if code not in (0,2):a.finding('OFFLINE_AUDIT_ERROR','unknown','离线检测器失败，退出码 '+str(code),'查看 offline 目录中的日志，不得判定依赖完整')
    offline_findings(a,offline,args.kubernetes)
    assess_runtime_compatibility(a,host,args.kubernetes)
    if host.get('runtime'):
        write_json(a.out/'runtime-report.json',host['runtime'])
        render_runtime_report(host['runtime'],a.out)
    configs=write_configs(a,host,args.kubernetes)
    mode_status={mode:outcome(a.findings,mode) for mode in deployment_modes(host)}
    selected_mode='data-disk' if host.get('prepared_storage') else 'native'
    data=dict(schema=1,generated_at=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),status=mode_status[selected_mode],selected_mode=selected_mode,mode_status=mode_status,
              host=host,findings=a.findings,checks=a.events,configurations=configs,
              offline_report_path=str(offline_path) if offline_path else None,offline=offline)
    write_json(args.output/'report.json',data);render_report(data,args.output)
    print('[预检完成] '+str(args.output/'preflight-report.md'),flush=True)
    return 2 if data['status']=='blocked_or_incomplete' else 0


if __name__=='__main__':
    sys.exit(main())
