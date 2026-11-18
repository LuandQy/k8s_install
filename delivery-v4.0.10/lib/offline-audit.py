#!/usr/bin/env python3
"""Read-only offline delivery audit. Writes only reports/cache under --output.

No mounts, installation, service actions or network sources are used. APT uses
an isolated config/status/cache and simulation; its local file index is prepared
with `update` inside that isolated tree, never /var/lib/apt.
"""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import time
import threading

NODE = ['socat', 'conntrack', 'ipset', 'ebtables', 'ipvsadm', 'tar', 'iptables', 'nfs-common', 'chrony']
BOOTSTRAP = ['jq', 'util-linux', 'openssh-client', 'sshpass']
ALL = NODE + ['nfs-kernel-server'] + BOOTSTRAP + ['python3']


def normalize_arch(machine):
    value = (machine or '').lower()
    if value in ('x86_64', 'amd64'):
        return 'amd64'
    if value in ('aarch64', 'arm64'):
        return 'arm64'
    raise ValueError('不支持的架构: ' + str(machine))


def bootstrap_archives(root, arch):
    tokens = {'amd64': ('amd64',), 'arm64': ('arm64', 'aarch64')}[normalize_arch(arch)]
    return [path for path in sorted((Path(root) / 'bootstrap').glob('bootstrap-*.tar.gz'))
            if any(path.name.endswith('-' + token + '.tar.gz') for token in tokens)]


def iso_members(names, arch):
    suffix = '-' + normalize_arch(arch) + '.iso'
    return sorted(name for name in names if name.startswith('repository/') and name.endswith(suffix))


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(4*1024*1024), b''):
            h.update(chunk)
    return h.hexdigest()


def relative(name):
    name = name.removeprefix('./') if hasattr(str, 'removeprefix') else (name[2:] if name.startswith('./') else name)
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or not name or '\\' in name:
        raise ValueError('unsafe archive/index path: ' + name)
    return name


def target_under(base, name):
    target = base/relative(name)
    try: target.resolve().relative_to(base.resolve())
    except ValueError: raise ValueError('cache path escapes output directory: '+name)
    return target


def deb822(text):
    result = []; record = {}; key = None
    for line in text.splitlines() + ['']:
        if not line:
            if record: result.append(record)
            record = {}; key = None
        elif line[0].isspace() and key:
            record[key] += '\n' + line
        elif ':' in line:
            key, value = line.split(':', 1); record[key] = value.strip()
    return result


def run(args, logfile, env=None, timeout=90, stdout=None):
    with Path(logfile).open('wb') as log:
        p = subprocess.run(args, stdout=stdout or log, stderr=log,
                           env=env, timeout=timeout, check=False)
    return p.returncode


def extract_tar(source, dest, select=lambda name: True):
    index = []
    with tarfile.open(source, 'r|gz') as archive:
        for member in archive:
            if member.isdir(): continue
            name = relative(member.name)
            if not member.isfile(): raise ValueError('archive has link/special file: '+name)
            index.append({'name': name, 'size': member.size})
            if select(name):
                target = target_under(dest, name); target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('wb') as out:
                    shutil.copyfileobj(archive.extractfile(member), out)
    return index


class Audit:
    def __init__(self, root, out, version, arch='amd64'):
        self.root, self.out, self.version = root, out, version
        self.arch = normalize_arch(arch)
        self.cache = out/'cache'; self.cache.mkdir(parents=True, exist_ok=True)
        self.checks = []; self.start = time.monotonic()
        self.stage='准备检测'
        self.data = {'schema':1, 'root':str(root), 'kubernetes':version, 'architecture':self.arch,
                     'generated_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     'evidence_inputs':{'media':[]},
                     'network_used':False, 'installed_anything':False, 'mounted_anything':False,
                     'checks':self.checks, 'limitations':[
                         'APT simulation does not run package maintainer scripts, start services or prove reboot/runtime compatibility.',
                         'Empty dpkg status tests package closure; it is stricter than a supported fresh Ubuntu base OS.',
                         'OCI descriptor presence and manifest hashes are checked; no actual registry push or CRI pull is performed.']}

    def progress(self, number, message):
        self.stage=message
        print('[离线预检 %s/7] %s（%.1fs）' % (number, message, time.monotonic()-self.start), file=sys.stderr, flush=True)

    def fingerprint(self, path, sha256=None):
        st=path.stat()
        return dict(path=str(path.resolve()),size=st.st_size,mtime_ns=st.st_mtime_ns,
                    sha256=sha256 or digest(path))

    def track_source(self, path, sha256=None):
        try: path.resolve().relative_to(self.root)
        except ValueError:return
        entry=self.fingerprint(path,sha256)
        if not any(e['path']==entry['path'] for e in self.data['evidence_inputs']['media']):
            self.data['evidence_inputs']['media'].append(entry)

    def add(self, code, status, detail, severity='blocker', **extra):
        self.checks.append(dict(code=code, status=status, detail=detail, severity=severity, **extra))
        if status != 'passed': print('[%s] %s: %s' % (status.upper(), code, detail), file=sys.stderr, flush=True)

    def checksums(self, manifest, base, optional=()):
        results = []
        self.track_source(manifest)
        # Entries may carry a third column (for example the KubeKey version in
        # lib/kk-binaries.sha256). One file can only match one recorded build, so
        # group by name and accept a match against any recorded entry; comment
        # lines and blank lines are not checks.
        entries = {}
        for line in manifest.read_text().splitlines():
            text = line.strip()
            if not text or text.startswith('#'): continue
            parts = text.split()
            if len(parts) < 2: continue
            expected, name = parts[0], relative(parts[1].lstrip('*'))
            version = parts[2] if len(parts) > 2 else ''
            entries.setdefault(name, []).append((expected, version))
        for name, candidates in entries.items():
            file = base/name
            actual = digest(file) if file.is_file() else None
            if actual is not None:self.track_source(file,actual)
            matched = [version for expected, version in candidates if actual == expected]
            passed = bool(matched)
            expected = candidates[0][0] if len(candidates) == 1 else '|'.join(item[0] for item in candidates)
            if passed and len(candidates) > 1:
                detail = 'SHA256 matched recorded ' + (', '.join(matched) or 'entry')
            else:
                detail = 'SHA256 matched' if passed else ('file missing' if actual is None else 'SHA256 mismatch')
            severity = 'warning' if name in optional else 'blocker'
            self.add('sha256:'+name, 'passed' if passed else 'failed', detail, severity,
                     path=str(file), expected=expected, actual=actual,
                     versions=[version for _expected, version in candidates])
            results.append({'name':name, 'expected':expected, 'actual':actual, 'passed':passed})
        return results

    def package_repo(self, repo):
        index = repo/'Packages'
        if not index.exists():
            index.write_bytes(gzip.decompress((repo/'Packages.gz').read_bytes()))
        packages = deb822(index.read_text())
        failures = []
        for pkg in packages:
            filename = relative(pkg['Filename']); file = target_under(repo, filename)
            if not file.is_file(): failures.append(pkg['Package']+':missing:'+filename); continue
            expected = pkg.get('SHA256', '')
            if not re.fullmatch('[0-9a-f]{64}', expected): failures.append(pkg['Package']+':missing_sha256'); continue
            if file.stat().st_size != int(pkg['Size']) or digest(file) != expected:
                failures.append(pkg['Package']+':size_or_sha256_mismatch')
                continue
            if shutil.which('dpkg-deb'):
                fields=('Package','Version','Architecture','Depends','Pre-Depends')
                control=subprocess.check_output(['dpkg-deb','-f',str(file),*fields],text=True)
                actual=deb822(control)[0]
                if any(' '.join(actual.get(k,'').split())!=' '.join(pkg.get(k,'').split()) for k in fields):
                    failures.append(pkg['Package']+':control_metadata_mismatch')
        self.add('package_files:'+repo.name, 'failed' if failures else 'passed',
                 failures or '%d package files match index sizes and SHA256' % len(packages), repository=str(repo))
        return packages

    def iso_repo(self, iso):
        repo = self.cache/'iso-repo'; repo.mkdir(exist_ok=True)
        if not shutil.which('7z'):
            self.add('iso_reader', 'unknown', '7z is unavailable; cannot inspect ISO without mounting')
            return None
        listing = subprocess.check_output(['7z','l','-slt',str(iso)], text=True)
        (self.out/'iso-list.txt').write_text(listing)
        entries = deb822(listing.replace(' = ', ': '))
        # Only entries after the archive metadata header have the Folder field.
        files = []
        for entry in entries:
            if entry.get('Folder') != '-': continue
            name = relative(entry['Path'])
            if entry.get('Symbolic Link'): raise ValueError('ISO contains symbolic link')
            if name.endswith('.deb') or name in ('Packages', 'Packages.gz'):
                files.append(name)
        if not any(n in ('Packages','Packages.gz') for n in files):
            raise ValueError('ISO missing root Packages/Packages.gz')
        for name in files:
            target=target_under(repo,name); target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('wb') as out:
                if run(['7z','x','-so',str(iso),name], self.out/'iso-extract.log', stdout=out):
                    raise ValueError('ISO extraction failed: '+name)
        return repo

    def apt_simulate(self, label, repos, targets, installed=True):
        work=self.out/('apt-'+label); work.mkdir(exist_ok=True)
        for name in ('lists/partial','archives/partial','log','empty'): (work/name).mkdir(parents=True,exist_ok=True)
        status=work/'status'
        if installed: shutil.copyfile(self.cache/'host-dpkg-status',status)
        else: status.write_text('')
        sources=work/'sources.list'
        sources.write_text(''.join('deb [trusted=yes] file:%s ./\n' % p for p in repos))
        config=work/'apt.conf'
        config.write_text('''Dir::Etc::main "/dev/null";
Dir::Etc::parts "%s";
Dir::Etc::sourcelist "%s";
Dir::Etc::sourceparts "%s";
Dir::Etc::preferences "/dev/null";
Dir::Etc::preferencesparts "%s";
Dir::State "%s";
Dir::State::status "%s";
Dir::State::lists "%s";
Dir::State::extended_states "%s";
Dir::Cache "%s";
Dir::Cache::archives "%s";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Dir::Log "%s";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
Acquire::Languages "none";
Acquire::AllowInsecureRepositories "true";
Debug::NoLocking "true";
''' % (work/'empty', sources, work/'empty',work/'empty', work, status, work/'lists',work/'extended_states',work,work/'archives',work/'log'))
        env=dict(os.environ,APT_CONFIG=str(config),LC_ALL='C')
        # Default hooks and network source directories are disabled in APT_CONFIG.
        rc=run(['apt-get','update'],work/'update.log',env=env)
        if rc:
            self.add('apt:'+label,'unknown','isolated local index failed: '+(work/'update.log').read_text(errors='replace')[-6000:],log=str(work/'update.log'))
            return {'status':'unknown','exit_code':rc,'targets':targets}
        rc=run(['apt-get','--simulate','--no-install-recommends','install',*targets],work/'simulate.log',env=env)
        output=(work/'simulate.log').read_text(errors='replace')
        removals=[line for line in output.splitlines() if line.startswith('Remv ')]
        if removals:
            self.add('apt_removals:'+label,'warning',removals,'warning')
        status_name='passed' if rc==0 else 'failed'
        self.add('apt:'+label,status_name,'dependency solver succeeded' if rc==0 else output[-6000:],
                 'blocker' if installed else 'warning',log=str(work/'simulate.log'),removals=removals)
        return {'status':status_name,'exit_code':rc,'targets':targets,'log':str(work/'simulate.log'),
                'would_remove':removals,'would_install':[line for line in output.splitlines() if line.startswith('Inst ')]}

    def execute(self):
        self.data['evidence_inputs']['dpkg_status']=self.fingerprint(Path('/var/lib/dpkg/status'))
        shutil.copyfile('/var/lib/dpkg/status',self.cache/'host-dpkg-status')
        if digest(self.cache/'host-dpkg-status')!=self.data['evidence_inputs']['dpkg_status']['sha256']:
            raise ValueError('system dpkg state changed during snapshot; retry audit')
        for path in (Path(__file__).resolve(),self.root/'lib/artifact-requirements.sh'):
            self.track_source(path)
        self.progress(1,'校验制品与 bootstrap 摘要')
        results=self.checksums(self.root/'artifact/SHA256SUMS',self.root/'artifact',
                              ('tools/amd64/oras_1.3.0_linux_amd64.tar.gz',))
        archive=next(x for x in results if x['name']=='kubekey-artifact.tgz')
        self.data['artifact_sha256']=archive['actual']
        self.data['artifact_manifest_complete']=all(x['passed'] for x in results)
        bootstrap_sums = sorted((self.root/'bootstrap').glob('bootstrap-*.tar.gz.sha256'))
        if not bootstrap_sums:
            self.add('bootstrap_manifest', 'failed', 'bootstrap/ 缺少任何 bootstrap-*.tar.gz.sha256')
        for manifest in bootstrap_sums:
            self.checksums(manifest, self.root/'bootstrap')
        self.checksums(self.root/'lib/kk-binaries.sha256',self.root)
        if not archive['passed']: return
        self.progress(2,'读取归档目录和 Ubuntu 24.04 amd64 ISO，不挂载')
        binding=self.cache/'source-sha256'
        index_path=self.cache/'archive-index.json'
        # The cache is trusted only if all extracted files match its saved hashes.
        files_path=self.cache/'extracted-sha256.json'
        valid=False
        if binding.exists() and index_path.exists() and files_path.exists() and binding.read_text()==archive['actual']:
            saved=json.loads(files_path.read_text())
            valid=all(target_under(self.cache,n).is_file() and digest(target_under(self.cache,n))==h for n,h in saved.items())
        if valid: index=json.loads(index_path.read_text())
        else:
            index=extract_tar(self.root/'artifact/kubekey-artifact.tgz',self.cache,
                              lambda n:n.endswith('.iso') or n=='manifests.yaml' or '/manifests/' in n)
            index_path.write_text(json.dumps(index,indent=2))
            saved={str(p.relative_to(self.cache)):digest(p) for p in self.cache.rglob('*') if p.is_file()
                   and (str(p.relative_to(self.cache)).endswith('.iso') or str(p.relative_to(self.cache))=='manifests.yaml' or '/manifests/' in str(p.relative_to(self.cache)))}
            files_path.write_text(json.dumps(saved,indent=2));binding.write_text(archive['actual'])
        names={v['name'] for v in index};self.data['archive_member_count']=len(index)
        candidates=iso_members(names,self.arch)
        if not candidates:
            self.add('iso_architecture','failed','归档中没有 %s 架构的 repository/*.iso' % self.arch)
            return
        self.iso_member=candidates[0]
        script='''ROOT="$1"; KUBE_VERSION="$2"; NODE_ARCH="$3"; COMPONENTS=all; LOCAL_STORAGE=true; NFS_MODE=new
has_role() { [ "$1" = registry ]; }
. "$ROOT/lib/artifact-requirements.sh"
artifact_required_members
'''
        required=subprocess.check_output(['bash','-c',script,'audit',str(self.root),self.version,self.arch],text=True).splitlines()+[self.iso_member]
        missing=sorted(set(required)-names)
        self.add('selected_artifact_members','failed' if missing else 'passed',missing or '%d selected binary/chart/ISO paths present' % len(required))
        self.data['required_members']=required
        self.progress(3,'读取并逐个校验 ISO 软件包')
        iso=self.cache/self.iso_member
        if not iso.exists(): self.add('ubuntu_iso','failed','selected ISO missing'); return
        repo=self.iso_repo(iso)
        if repo is None:return
        packages=self.package_repo(repo)
        self.progress(4,'校验 bootstrap 包及本机软件包状态')
        boot=self.cache/'bootstrap-repo';boot.mkdir(exist_ok=True)
        candidates=bootstrap_archives(self.root,self.arch)
        if not candidates:
            self.add('bootstrap_architecture','failed','bootstrap/ 中没有 %s 架构的离线包' % self.arch)
            return
        self.data['bootstrap_archive']=str(candidates[0])
        extract_tar(candidates[0],boot)
        if (boot/'SHA256SUMS').is_file(): self.checksums(boot/'SHA256SUMS',boot)
        boot_packages=self.package_repo(boot) if (boot/'Packages').is_file() or (boot/'Packages.gz').is_file() else []
        self.data['package_catalog']={'iso':[{k:p.get(k,'') for k in ('Package','Version','Architecture','Depends','Pre-Depends')} for p in packages],
                                      'bootstrap':[{k:p.get(k,'') for k in ('Package','Version','Architecture','Depends','Pre-Depends')} for p in boot_packages]}
        available={p['Package'] for p in packages+boot_packages}
        query=subprocess.run(['dpkg-query','-W','-f=${Package}\t${Version}\t${Status}\n',*sorted(set(ALL))],capture_output=True,text=True)
        installed={line.split('\t')[0]:line.split('\t')[1] for line in query.stdout.splitlines() if line.endswith('install ok installed')}
        self.data['packages']=[{'package':p,'on_media':p in available,'installed_version':installed.get(p)} for p in sorted(set(ALL))]
        for p in sorted(set(ALL)-available):
            self.add('package_on_media:'+p,'failed','package absent from ISO and bootstrap; host installed='+str(installed.get(p)),
                     'warning' if p in installed else 'blocker')
        self.progress(5,'隔离 APT 模拟当前本机依赖解析（仅 file: 源）')
        if not shutil.which('apt-get'):
            self.add('apt_solver','unknown','apt-get unavailable; dependency closure unverified');return
        self.data['simulations']={}
        for label, repos, targets in [('node-base',[repo],NODE),('node-nfs',[repo],NODE+['nfs-kernel-server']),
                                      ('bootstrap',[boot],BOOTSTRAP),('combined',[repo,boot],ALL)]:
            self.progress(5,'本机模拟 '+label)
            self.data['simulations'][label]=self.apt_simulate(label,repos,targets)
        self.progress(6,'空 dpkg 状态解析，检验介质自身的包依赖闭包')
        self.data['simulations']['empty-state']=self.apt_simulate('empty-state',[repo,boot],ALL,installed=False)
        self.data['simulations']['empty-state-present-packages']=self.apt_simulate(
            'empty-state-present-packages',[repo,boot],[p for p in ALL if p in available],installed=False)
        self.progress(7,'检查 OCI manifests 引用与摘要')
        missing_refs=[];bad=[];checked=0
        for file in (self.cache/'images').rglob('sha256:*'):
            if '/manifests/' not in str(file):continue
            if 'sha256:'+digest(file)!=file.name:bad.append(str(file.relative_to(self.cache)))
            data=json.loads(file.read_text());checked+=1
            for descriptor in data.get('manifests',[])+data.get('layers',[])+([data['config']] if 'config' in data else []):
                value=descriptor.get('digest','')
                prefix=str(file.parent.relative_to(self.cache))
                if prefix+'/'+value not in names and 'images/blobs/'+value not in names:missing_refs.append(value)
        self.add('oci_manifest_sha256','failed' if bad else 'passed',bad or '%d manifests match digest filenames' % checked)
        self.add('oci_descriptor_presence','failed' if missing_refs else 'passed',sorted(set(missing_refs)) or 'all manifest/config/layer references present')

    def save(self):
        initial=self.data['evidence_inputs'].get('dpkg_status')
        if initial and digest(Path(initial['path']))!=initial['sha256']:
            self.add('dpkg_state_changed','unknown','system package state changed during audit; repeat before installation')
        self.data['blockers']=[c for c in self.checks if c['status'] in ('failed','unknown') and c['severity']=='blocker']
        self.data['warnings']=[c for c in self.checks if c['status']!='passed' and c['severity']=='warning']
        self.data['status']='blocked' if self.data['blockers'] else 'checked_with_limits'
        self.data['elapsed_seconds']=round(time.monotonic()-self.start,2)
        (self.out/'report.json').write_text(json.dumps(self.data,ensure_ascii=False,indent=2)+'\n')
        print('[离线预检完成] %s；阻塞 %d 项；报告 %s' % (self.data['status'],len(self.data['blockers']),self.out/'report.json'),file=sys.stderr)
        return 2 if self.data['blockers'] else 0


def kubernetes_versions(root):
    found=[]
    for path in sorted((Path(root) / 'configs').glob('v*.yaml')):
        if not re.fullmatch(r'v\d+\.\d+\.\d+', path.stem):
            continue
        body=path.read_text(encoding='utf-8')
        match=re.search(r'^\s*kube_version:\s*["\']?(v\d+\.\d+\.\d+)', body, re.MULTILINE)
        if not match or match.group(1) != path.stem:
            raise ValueError('版本文件与 kube_version 不一致: '+path.name)
        found.append(path.stem)
    if not found:
        raise ValueError('configs/ 下没有可用的 Kubernetes 版本文件')
    return sorted(set(found), key=lambda value: tuple(int(x) for x in re.findall(r'\d+', value)), reverse=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--kubernetes')
    parser.add_argument('--arch')
    args=parser.parse_args()
    try:
        versions=kubernetes_versions(args.root)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.kubernetes is None:
        args.kubernetes=versions[0]
    elif args.kubernetes not in versions:
        parser.error('invalid Kubernetes version: '+args.kubernetes)
    os.umask(0o077)
    try:args.output.mkdir(parents=True,exist_ok=False)
    except OSError as error:parser.error('output must be a new directory: '+str(error))
    try:
        arch=normalize_arch(args.arch or __import__('platform').machine())
    except ValueError as error:
        parser.error(str(error))
    audit=Audit(args.root.resolve(),args.output.resolve(),args.kubernetes,arch)
    stop=threading.Event()
    def heartbeat():
        while not stop.wait(10):
            print('[离线预检进行中] %s；累计 %.1fs' % (audit.stage,time.monotonic()-audit.start),file=sys.stderr,flush=True)
    worker=threading.Thread(target=heartbeat,daemon=True);worker.start()
    try:
        audit.execute()
    except (OSError,ValueError,KeyError,tarfile.TarError,subprocess.SubprocessError) as error:
        audit.add('audit_error','unknown',str(error));audit.save();return 1
    finally:
        stop.set();worker.join(timeout=1)
    return audit.save()


if __name__=='__main__':sys.exit(main())
