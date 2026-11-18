"""Read-only Docker/containerd inventory. No authentication material is collected.

The caller supplies its command runner and finding recorder. Every daemon command
is pinned to a local socket. Only list/inspect/version/du operations are used.
"""
import json
import re
import sys


DOCKER = ['docker', '--host', 'unix:///var/run/docker.sock']
INFO = '{"root":{{json .DockerRootDir}},"server_version":{{json .ServerVersion}},"driver":{{json .Driver}},"driver_status":{{json .DriverStatus}},"containers":{{json .Containers}},"running":{{json .ContainersRunning}},"images":{{json .Images}}}'
CONTAINER = ('{"id":{{json .Id}},"name":{{json .Name}},"image_id":{{json .Image}},'
             '"image_ref":{{json .Config.Image}},"state":{{json .State.Status}},'
             '"exit_code":{{json .State.ExitCode}},"oom_killed":{{json .State.OOMKilled}},'
             '"log_path":{{json .LogPath}},"size_rw":{{json .SizeRw}},"size_rootfs":{{json .SizeRootFs}},'
             '"mounts":[{{range $i,$m := .Mounts}}{{if $i}},{{end}}'
             '{"type":{{json (index $m "Type")}},"name":{{json (index $m "Name")}},"source":{{json (index $m "Source")}},'
             '"destination":{{json (index $m "Destination")}},"rw":{{json (index $m "RW")}}}{{end}}]}')
IMAGE = '{"id":{{json .Id}},"tags":{{json .RepoTags}},"digests":{{json .RepoDigests}},"size_bytes":{{json .Size}}}'
VOLUME = '{"name":{{json .Name}},"driver":{{json .Driver}},"mountpoint":{{json .Mountpoint}},"scope":{{json .Scope}}}'

# Read argv/config in a privileged subprocess, but emit only storage/socket
# fields. Do not expose process arguments, environment, TOML or registry auth.
DISCOVER = r'''
import json,os,re,stat
from pathlib import Path
def fields(text):
    result={};section='';imports=False
    for line in text.splitlines():
        line=line.strip()
        if line.startswith('['):section=line
        match=re.match(r'(root|state|address)\s*=\s*(["\x27])(.*?)\2\s*(?:#.*)?$',line)
        if match and (not section or section=='[grpc]'):
            if match[1] in ('root','state') and not section:result[match[1]]=match[3]
            if match[1]=='address' and section=='[grpc]':result['socket']=match[3]
        if not section and re.match(r'imports\s*=\s*\[(?!\s*\])',line):imports=True
    return result,imports
items=[];errors=[]
for entry in Path('/proc').iterdir():
    if not entry.name.isdigit():continue
    try:
        if (entry/'comm').read_text().strip()!='containerd':continue
        argv=(entry/'cmdline').read_bytes().decode(errors='replace').strip('\0').split('\0')
        opts={}
        for i,arg in enumerate(argv):
            for key,flags in [('root',['--root']),('state',['--state']),('socket',['--address','-a']),('config',['--config','-c'])]:
                for flag in flags:
                    if arg==flag and i+1<len(argv):opts[key]=argv[i+1]
                    elif arg.startswith(flag+'='):opts[key]=arg.split('=',1)[1]
        config=opts.get('config','/etc/containerd/config.toml');values={};imports=False
        if Path(config).exists():values,imports=fields(Path(config).read_text())
        values.update({k:v for k,v in opts.items() if k in ('root','state','socket')})
        values.setdefault('root','/var/lib/containerd');values.setdefault('state','/run/containerd')
        values.setdefault('socket','/run/containerd/containerd.sock')
        items.append(dict(values,pid=int(entry.name),config=config,source='process argv + current config/defaults',unresolved_imports=imports))
    except FileNotFoundError:pass
    except (OSError,ValueError) as e:errors.append({'pid':entry.name,'error':type(e).__name__})
for socket in ('/run/containerd/containerd.sock','/var/run/docker/containerd/containerd.sock'):
    try:
        if stat.S_ISSOCK(Path(socket).stat().st_mode) and not any(os.path.realpath(i['socket'])==os.path.realpath(socket) for i in items):
            items.append(dict(socket=socket,root=None,state=None,source='known local socket; process/config unknown'))
    except FileNotFoundError:pass
    except OSError as e:errors.append({'socket':socket,'error':type(e).__name__})
print(json.dumps({'instances':items,'errors':errors}))
'''


# Absence is a positive, privileged check, never inferred from a failed daemon
# query. Retained configuration prevents skipping: it may refer to another root.
PRESENCE = r'''
import json,os,shutil
from pathlib import Path
result={'privileged':os.geteuid()==0,'errors':[],'processes':[],'binaries':{},'paths':{}}
for binary in ('docker','dockerd','ctr','containerd'):
    result['binaries'][binary]=shutil.which(binary)
for entry in Path('/proc').iterdir():
    if not entry.name.isdigit():continue
    try:
        name=(entry/'comm').read_text().strip()
        if name in ('dockerd','containerd'):result['processes'].append(name)
    except FileNotFoundError:pass
    except OSError as e:result['errors'].append({'pid':entry.name,'error':type(e).__name__})
for name in ('/var/run/docker.sock','/run/containerd/containerd.sock','/var/run/docker/containerd/containerd.sock',
             '/etc/docker/daemon.json','/etc/containerd/config.toml'):
    try:Path(name).lstat();result['paths'][name]=True
    except FileNotFoundError:result['paths'][name]=False
    except OSError as e:result['paths'][name]=None;result['errors'].append({'path':name,'error':type(e).__name__})
print(json.dumps(result))
'''


def absence_verified(name, presence, services, directories):
    """Only a positively empty, uninstalled default runtime can skip inventory."""
    if not isinstance(presence,dict) or presence.get('privileged') is not True or presence.get('errors') != []:
        return False
    rules={
        'docker':(('docker','dockerd'),('docker.service','docker.socket'),
                  ('/var/run/docker.sock','/var/run/docker/containerd/containerd.sock','/etc/docker/daemon.json'),'/var/lib/docker','dockerd'),
        'containerd':(('ctr','containerd'),('containerd.service',),
                      ('/run/containerd/containerd.sock','/var/run/docker/containerd/containerd.sock','/etc/containerd/config.toml'),'/var/lib/containerd','containerd')}
    binaries,units,paths,root,process=rules[name]
    if not isinstance(presence.get('binaries'),dict) or any(b not in presence['binaries'] or presence['binaries'][b] is not None for b in binaries):
        return False
    if not isinstance(presence.get('processes'),list) or process in presence['processes']:
        return False
    if any((presence.get('paths') or {}).get(path) is not False for path in paths):
        return False
    by_name={item.get('Id'):item for item in services or []}
    for unit in units:
        state=by_name.get(unit,{})
        if state.get('ActiveState') != 'inactive' or state.get('LoadState') not in ('loaded','not-found','masked'):
            return False
    data=next((item for item in directories or [] if item.get('path')==root),{})
    if data.get('content_status')=='unknown' or data.get('error'):
        return False
    return data.get('exists') is False or (data.get('exists') is True and data.get('top_level_entries')==0)


def _table(text, kind):
    lines=[line for line in text.splitlines() if line.strip()]
    expected={'tasks':'TASK', 'snapshots':'KEY', 'plugins':'TYPE'}[kind]
    if not lines or lines[0].split()[0]!=expected:
        raise ValueError('missing '+kind+' table header')
    items=[]
    for line in lines[1:]:
        parts=line.split()
        if kind=='tasks':
            if len(parts)!=3 or not parts[1].isdigit():raise ValueError('invalid task row')
            items.append(dict(id=parts[0],pid=int(parts[1]),status=parts[2]))
        elif kind=='snapshots':
            if len(parts) not in (2,3):raise ValueError('invalid snapshot row')
            items.append(dict(key=parts[0],parent=parts[1] if len(parts)==3 else None,kind=parts[-1]))
        elif kind=='plugins':
            if len(parts)<4:raise ValueError('invalid plugin row')
            items.append(dict(type=parts[0],id=parts[1],status=parts[-1]))
    return items


def collect(run, finding, docker_info=None, directories=None, presence=None, services=None):
    """Return inventory; None means unavailable, [] means a successful empty list."""
    issues=[]
    def unknown(key, message):
        issues.append(key)
        finding('RUNTIME_'+key.upper().replace('-','_'),'unknown',message,'查看对应运行时检测日志后只读复检；不要按空环境处理')

    def call(key,label,args,parse=None,timeout=40):
        result=run('runtime-'+key,label,args,timeout=timeout,privileged=True)
        if result['returncode']:
            unknown(key,label+' 未完成：'+result.get('error',''))
            return None
        try:return parse(result['stdout']) if parse else result['stdout']
        except (ValueError,TypeError,KeyError) as e:
            unknown(key,label+' 返回格式无法识别：'+str(e));return None

    def obj(text):
        value=json.loads(text)
        if not isinstance(value,dict):raise ValueError('expected JSON object')
        return value

    def lines(text):return [line for line in text.splitlines() if line]

    measured={}
    for item in directories or []:
        if isinstance(item.get('bytes'),int) and not item.get('symlink'):
            measured[item['path']]=dict(path=item['path'],bytes=item['bytes'],status='passed',measurement='du allocated bytes, existing preflight result')

    def storage(path,source):
        if not isinstance(path,str) or not path.startswith('/') or '\n' in path or '\0' in path:
            unknown('storage-path','未获得有效绝对数据路径');return dict(path=path,source=source,bytes=None,status='unknown')
        if path not in measured:
            index=len(measured)
            def size(text):
                value=text.split('\t',1)[0].strip()
                if not value.isdigit():raise ValueError('invalid du byte count')
                return int(value)
            value=call('size-'+str(index),'只读统计 '+path,['du','-sxH','--block-size=1','--',path],size,timeout=90)
            measured[path]=dict(path=path,bytes=value,status='passed' if value is not None else 'unknown',measurement='du allocated bytes, follows command-line symlink only, no filesystem crossing')
        return dict(measured[path],source=source)

    # Query the daemon for driver_status even if the caller already supplied its
    # summary. DriverStatus identifies Docker's containerd image-store backend.
    docker_absent=absence_verified('docker',presence,services,directories)
    info=None if docker_absent else call('docker-info','Docker 数据根和存储后端',DOCKER+['info','--format',INFO],obj)
    if info is not None:
        info={key:info.get(key) for key in ('root','server_version','driver','driver_status','containers','running','images')}
    if info is not None and not info.get('server_version'):
        unknown('docker-info','Docker 缺少服务端版本，不能判为可访问');info=None
    docker=dict(status='not_installed' if docker_absent else 'available' if info else 'unknown',
                inventory_status='not_applicable' if docker_absent else 'queried',
                info=info,containers=None,images=None,volumes=None,usage=None,storage_paths=[])
    if info is not None:
        ids=call('docker-containers','列出所有 Docker 容器',DOCKER+['container','ls','--all','--quiet','--no-trunc'],lines)
        if ids is not None:
            docker['containers']=[]
            for index,cid in enumerate(ids):
                item=call('docker-container-'+str(index),'只读核实 Docker 容器 '+cid[:12],DOCKER+['container','inspect','--size','--format',CONTAINER,cid],obj,timeout=90)
                if item is None:
                    docker['containers'].append(dict(id=cid,status='unknown'));continue
                # Reapply whitelist even if a test fixture/new CLI emits extras.
                fields=('id','name','image_id','image_ref','state','exit_code','oom_killed','log_path','size_rw','size_rootfs')
                clean={k:item.get(k) for k in fields}
                mounts=item.get('mounts')
                if not isinstance(mounts,list):unknown('docker-mounts-'+str(index),'容器挂载清单格式无效');clean['mounts']=None
                else:
                    clean['mounts']=[{k:mount.get(k) for k in ('type','name','source','destination','rw')} for mount in mounts if isinstance(mount,dict)]
                    for mount in clean['mounts']:
                        if mount['type'] in ('bind','volume') and mount['source']:
                            docker['storage_paths'].append(storage(mount['source'],'container '+str(clean['name'])+' '+mount['type']+' mount'))
                docker['containers'].append(clean)
        image_ids=call('docker-images','列出全部 Docker 镜像 ID',DOCKER+['image','ls','--all','--quiet','--no-trunc'],lines)
        if image_ids is not None:
            docker['images']=[]
            for index,iid in enumerate(dict.fromkeys(image_ids)):
                item=call('docker-image-'+str(index),'读取镜像引用、摘要和逻辑大小',DOCKER+['image','inspect','--format',IMAGE,iid],obj)
                docker['images'].append({k:item.get(k) for k in ('id','tags','digests','size_bytes')} if item else dict(id=iid,status='unknown'))
        names=call('docker-volumes','列出 Docker 管理卷',DOCKER+['volume','ls','--quiet'],lines)
        if names is not None:
            docker['volumes']=[]
            for index,name in enumerate(names):
                item=call('docker-volume-'+str(index),'读取 Docker 卷路径',DOCKER+['volume','inspect','--format',VOLUME,name],obj)
                clean={k:item.get(k) for k in ('name','driver','mountpoint','scope')} if item else dict(name=name,status='unknown')
                docker['volumes'].append(clean)
                if clean.get('mountpoint'):docker['storage_paths'].append(storage(clean['mountpoint'],'docker volume '+name))
        def jsonlines(text):
            values=[obj(line) for line in text.splitlines() if line]
            if not values:raise ValueError('empty docker system df output')
            return [{k:v.get(k) for k in ('Type','TotalCount','Active','Size','Reclaimable')} for v in values]
        docker['usage']=call('docker-df','Docker 容器/镜像/卷/构建缓存统计',DOCKER+['system','df','--format','{{json .}}'],jsonlines,timeout=90)
        if info.get('root'):docker['storage_paths'].append(storage(info['root'],'docker data root'))

    containerd_absent=absence_verified('containerd',presence,services,directories)
    discovery=dict(instances=[],errors=[]) if containerd_absent else call(
        'containerd-discovery','发现 containerd 进程、socket 和数据路径',[sys.executable,'-c',DISCOVER],obj)
    containerd=dict(status='not_installed' if containerd_absent else 'queried',
                    inventory_status='not_applicable' if containerd_absent else 'queried',instances=None,storage_paths=[])
    if discovery is not None:
        if discovery.get('errors'):unknown('containerd-discovery','部分 containerd 进程/配置无法读取：'+str(discovery['errors']))
        containerd['instances']=[]
        if not discovery.get('instances') and not containerd_absent:
            unknown('containerd-inactive','未发现可查询的 containerd 实例，但未证明二进制、配置和数据均为空；不能按空环境处理')
        seen=set()
        for number,item in enumerate(discovery.get('instances',[])):
            socket=item.get('socket')
            if not isinstance(socket,str) or not socket.startswith('/'):
                unknown('containerd-socket','containerd 未获得本机 Unix socket 路径');continue
            if socket in seen:continue
            seen.add(socket)
            entry={k:item.get(k) for k in ('socket','root','state','pid','config','source','unresolved_imports')}
            containerd['instances'].append(entry)
            key='ctr-'+str(number);base=['ctr','--address',socket,'--timeout','20s','--connect-timeout','5s']
            entry['version']=call(key+'-version','读取 containerd 客户端/服务端版本',base+['version'])
            if item.get('unresolved_imports'):
                unknown(key+'-config','containerd 配置含 imports，数据根路径仍需核对有效导入配置')
            if item.get('root'):containerd['storage_paths'].append(storage(item['root'],'containerd root '+socket))
            else:unknown(key+'-root','containerd 数据根目录未核实：'+socket)
            plugins=call(key+'-plugins','列出 containerd snapshotter 状态',base+['plugins','list'],lambda text:_table(text,'plugins'))
            entry['snapshotters']=[p['id'] for p in plugins if p['type']=='io.containerd.snapshotter.v1' and p['status']=='ok'] if plugins is not None else None
            names=call(key+'-namespaces','枚举全部 containerd namespaces',base+['namespaces','list','--quiet'],lines)
            entry['namespaces']=None if names is None else []
            for index,name in enumerate(names or []):
                ns=dict(name=name);entry['namespaces'].append(ns);prefix=key+'-ns-'+str(index)
                args=base+['--namespace',name]
                ns['containers']=call(prefix+'-containers','containerd '+name+' 容器清单',args+['containers','list','--quiet'],lines)
                ns['images']=call(prefix+'-images','containerd '+name+' 镜像引用',args+['images','list','--quiet'],lines)
                ns['tasks']=call(prefix+'-tasks','containerd '+name+' 运行任务',args+['tasks','list'],lambda text:_table(text,'tasks'))
                ns['snapshots']=None if entry['snapshotters'] is None else []
                for snumber,snapshotter in enumerate(entry['snapshotters'] or []):
                    snapshots=call(prefix+'-snapshots-'+str(snumber),'containerd '+name+' / '+snapshotter+' 快照',args+['snapshots','--snapshotter',snapshotter,'list'],lambda text:_table(text,'snapshots'))
                    ns['snapshots'].append(dict(snapshotter=snapshotter,entries=snapshots))
    result=dict(schema=1,status='incomplete' if issues else 'checked_read_only',docker=docker,containerd=containerd,
                unknown_checks=issues,absence_evidence=dict(presence=presence,services=services),limitations=[
                    'not_installed 仅表示二进制、服务、进程、socket、配置及默认目录共同证明未安装；容器/镜像计数不适用，不伪造 daemon 返回的 0。',
                    '只读即时清单不是冻结快照，运行时数据可能同时变化。',
                    '镜像逻辑大小、共享层、BuildKit 缓存和目录 du 口径重叠，不能相加；reclaimable 不等于获准删除。',
                    'Docker 卷数量不包括 bind mount；绑定目录的占用单独列出。',
                    'Docker 停止容器可能只在 Docker 元数据中，不出现在 ctr containers/tasks，不能解释为数据丢失。',
                    'containerd 没有 Docker volume 目录概念；此处列命名空间、镜像、任务和快照，不能据此认定业务存储为空。',
                    '数据根路径来自进程参数及当前配置文件/defaults；若服务启动后配置被改动，需再核实。'])
    return result
