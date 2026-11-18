#!/usr/bin/env python3
"""Offline Pod/network acceptance; local PVC remains on one selected node.

Admin credentials remain on the execution node and are used only in memory.
Failure never triggers resource cleanup. Successful cleanup uses saved UIDs.
"""
import argparse
import base64
import copy
import datetime
import hashlib
import http.client
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tarfile
import threading
import time
from urllib.parse import quote, urlsplit

LABEL = 'rise.io/cluster-verification'
DIGEST = re.compile(r'^sha256:[0-9a-f]{64}$')
IO_ERROR = re.compile(r'I/O error|input/output error|Buffer I/O|blk_update_request|blk_print_req_error|critical (?:medium|target|hardware) error|EXT4-fs (?:error|warning)|XFS.*(?:corruption|I/O error)|exfat.*(?:error|failed)|uas_eh_|USB disconnect|reset (?:SuperSpeed|high-speed|full-speed).*USB|device offline|rejecting I/O|Synchronize Cache.*failed|(?:sd |nvme|ata\d).*?(?:timed out|timeout|failed command|abort)', re.I)


def require(value, message):
    if not value:
        raise RuntimeError(message)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, data):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp-' + secrets.token_hex(4))
    with temporary.open('x') as stream:
        os.chmod(temporary, 0o600)
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def receipt(path, fingerprint):
    record = json.loads(Path(path).read_text())
    require(record.get('status') == 'succeeded', 'Prerequisite receipt is not succeeded: ' + str(path))
    require(record.get('fingerprint') == fingerprint, 'Prerequisite workflow fingerprint differs')
    evidence = record.get('evidence') or {}
    require(evidence.get('path') and evidence.get('sha256'), 'Missing prerequisite evidence')
    require(sha(evidence['path']) == evidence['sha256'], 'Prerequisite evidence SHA256 differs')
    return json.loads(Path(evidence['path']).read_text())


def select_image(registry, node_evidence, node, authority):
    candidates = []
    for image in registry.get('images', []):
        if image.get('repository') != 'openebs/linux-utils':
            continue
        top = image.get('digest', '')
        require(bool(DIGEST.fullmatch(top)), 'Invalid diagnostic image digest')
        children = {ref['child_digest'] for ref in image.get('references', [])
                    if ref.get('platform', {}).get('os') == 'linux'
                    and ref.get('platform', {}).get('architecture') == node['arch']
                    and DIGEST.fullmatch(ref.get('child_digest', ''))}
        if image.get('references') and not children:
            continue
        require(len(children) <= 1, 'Ambiguous diagnostic image architecture')
        allowed = children or {top}
        tag_ref = authority + '/' + image['repository'] + ':' + image['tag']
        for observed in node_evidence.get('images', []):
            if (observed.get('node'), observed.get('arch'), observed.get('image'), observed.get('result')) != (node['name'], node['arch'], tag_ref, 'passed'):
                continue
            require(observed.get('registry_digest') == top, 'Node image receipt refers to another registry manifest')
            observed_digests = {x.split('@', 1)[1] for x in observed.get('repo_digests', [])
                                if x.startswith(authority + '/openebs/linux-utils@') and '@' in x}
            matches = allowed & observed_digests
            # Some CRIs report only the verified manifest-list digest. Pin the
            # selected child when registry evidence identifies its architecture.
            if not matches and children and top in observed_digests:
                matches = children
            require(len(matches) <= 1, 'Ambiguous diagnostic image platform digest')
            for digest in matches:
                candidates.append(authority + '/openebs/linux-utils@' + digest)
    candidates = sorted(set(candidates))
    require(len(candidates) == 1, 'No unique previously accepted linux-utils image for selected node/architecture; import and verify offline diagnostic media first')
    return candidates[0]


def build_config(args):
    config = json.loads(Path(args.base).read_text())
    nodes = [n for n in config['nodes'] if 'control_plane' in n['roles']]
    require(nodes, 'No declared control plane')
    node = nodes[0]
    require(node['arch'] in ('amd64', 'arm64'), 'Unsupported node architecture')
    directory = Path(args.identity_dir)
    expected = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        parts = line.split()
        if len(parts) == 2:
            expected[parts[1]] = parts[0]
    require(expected.get('identity.json') == sha(directory / 'identity.json'), 'Cluster identity digest differs')
    identity = json.loads((directory / 'identity.json').read_text())
    require(identity.get('uid') and identity.get('tool') == 'kubekey-shell', 'Missing managed cluster identity')
    registry = receipt(args.registry_receipt, config['fingerprint'])
    node_images = receipt(args.node_receipt, config['fingerprint'])
    config['node'] = node
    config['cluster_uid'] = identity['uid']
    config['image'] = select_image(registry, node_images, node, config['harbor']['host'] + ':' + str(config['harbor']['port']))
    mode = config.get('verification', {}).get('mode', 'selected-node')
    require(mode in ('selected-node', 'cross-node'), 'Unsupported cluster verification mode')
    participants = [n for n in config['nodes'] if set(n.get('roles', [])) & {'control_plane', 'worker'}] if mode == 'cross-node' else [node]
    require(mode != 'cross-node' or len(participants) >= 2, 'Cross-node verification needs at least two Kubernetes nodes')
    require(len({n['name'] for n in participants}) == len(participants) and len({n['ip'] for n in participants}) == len(participants), 'Duplicate verification node name/IP')
    require(all(n['arch'] == node['arch'] for n in participants), 'Cross-node tool transfer currently requires one shared architecture')
    config['verification'] = {'mode': mode}
    config['verification_nodes'] = participants
    config['images'] = {n['name']: select_image(registry, node_images, n, config['harbor']['host'] + ':' + str(config['harbor']['port'])) for n in participants}
    ca = Path(args.ca).read_text()
    require('-----BEGIN CERTIFICATE-----' in ca and 'PRIVATE KEY' not in ca, 'Harbor CA must contain public certificates only')
    config['harbor_ca_sha256'] = sha(args.ca)
    save(args.output, config)


def dns_addresses(output):
    """Read answer addresses only; never confuse the DNS server with an answer."""
    answer = False
    found = []
    for line in output.splitlines():
        if re.match(r'^\s*Name\s*:', line):
            answer = True
            continue
        match = re.match(r'^\s*Address(?:\s+\d+)?\s*:\s*(\S+)', line)
        if answer and match:
            raw = match.group(1).split('#', 1)[0]
            try:
                found.append(str(ipaddress.ip_address(raw)))
            except ValueError:
                raise RuntimeError('Unparseable DNS answer address')
    return sorted(set(found))


def validate_addresses(values, expected):
    require(bool(values), 'DNS returned no address')
    parsed = [ipaddress.ip_address(x) for x in values]
    require(not any(x.is_loopback or x.is_unspecified or x.is_link_local or x.is_multicast for x in parsed), 'DNS returned loopback/unspecified/link-local/multicast address')
    expected_set = set(expected) if isinstance(expected, (list, tuple, set)) else {expected}
    require(bool(expected_set), 'Expected DNS address set cannot be empty')
    require(set(values) == expected_set, 'DNS returned an unexpected address: ' + ','.join(values))


def elf_info(path):
    data = Path(path).read_bytes()
    require(data[:6] == b'\x7fELF\x02\x01', 'Expected a 64-bit little-endian ELF: ' + str(path))
    machine = struct.unpack_from('<H', data, 18)[0]
    arch = {62: 'amd64', 183: 'arm64'}.get(machine)
    require(arch, 'Unsupported ELF architecture')
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    require(size >= 56 and offset + size * count <= len(data), 'Invalid ELF program headers')
    interpreter = None
    for index in range(count):
        header = offset + size * index
        if struct.unpack_from('<I', data, header)[0] == 3:
            start = struct.unpack_from('<Q', data, header + 8)[0]
            length = struct.unpack_from('<Q', data, header + 32)[0]
            require(start + length <= len(data), 'Invalid ELF interpreter')
            interpreter = data[start:start + length].rstrip(b'\0').decode()
    return arch, interpreter


def storage_base(annotation):
    if annotation.lstrip().startswith('['):
        rows = json.loads(annotation)
        values = [r['value'] for r in rows if r.get('name') == 'BasePath']
    else:
        values = re.findall(r'''(?m)^\s*-\s*name:\s*["']?BasePath["']?\s*\n\s*value:\s*([^\n]+)''', annotation)
        values = [v.strip().strip('"\'') for v in values]
    require(len(values) == 1 and isinstance(values[0], str), 'Missing/ambiguous OpenEBS BasePath annotation')
    return values[0]


def validate_pv(pv, claim, namespace, base, node, baseline):
    ref = pv['spec']['claimRef']
    require((ref.get('uid'), ref.get('namespace'), ref.get('name')) == (claim['metadata']['uid'], namespace, claim['metadata']['name']), 'PV claim UID/namespace/name changed')
    require(pv['spec']['persistentVolumeReclaimPolicy'] == 'Delete', 'Unexpected PV reclaim policy')
    path = Path(pv['spec']['local']['path'])
    root = Path(base)
    require(root.is_absolute() and root.resolve() == root, 'Local PV base is redirected')
    require(not path.is_symlink() and path.resolve().parent == root and path.name == 'pvc-' + claim['metadata']['uid'], 'PV path is not the exact new claim directory')
    require(str(path) not in baseline['base_children'] and pv['metadata']['name'] not in baseline['pvs'], 'PV or directory predates this run')
    terms = pv['spec'].get('nodeAffinity', {}).get('required', {}).get('nodeSelectorTerms', [])
    require(terms and all(any(x.get('key') == 'kubernetes.io/hostname' and x.get('operator') == 'In' and x.get('values') == [node] for x in t.get('matchExpressions', [])) for t in terms), 'PV affinity is not restricted to the selected node')
    return str(path)


class IOGuard:
    def __init__(self, output):
        self.output = Path(output)
        self.cursor = None
        self.failed = None
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.thread = None

    def scan(self, initial=False):
        with self.lock:
            if self.failed:
                raise RuntimeError(self.failed)
            args = ['journalctl', '-k', '-b', '--no-pager', '-o', 'json']
            args += ['-n', '1'] if initial else ['--after-cursor', self.cursor]
            result = subprocess.run(args, capture_output=True, text=True, timeout=8)
            require(result.returncode == 0, 'Cannot monitor kernel journal')
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
            require(not initial or (rows and rows[-1].get('__CURSOR')), 'Kernel journal has no usable cursor')
            if rows:
                self.cursor = rows[-1]['__CURSOR']
                save(self.output / 'io-cursor.json', {'cursor': self.cursor, 'checked_at': now()})
            faults = [] if initial else [r.get('MESSAGE', '') for r in rows if IO_ERROR.search(str(r.get('MESSAGE', '')))]
            if faults:
                self.failed = 'New storage I/O error: ' + str(faults[0])[:600]
                save(self.output / 'STOP-IO.json', {'at': now(), 'errors': faults})
                raise RuntimeError(self.failed)

    def start(self):
        require(not (self.output / 'STOP-IO.json').exists(), 'I/O stop latch already exists')
        self.scan(initial=True)
        def watch():
            while not self.stop.wait(0.5):
                try:
                    self.scan()
                except Exception as error:
                    self.failed = str(error)
                    return
        self.thread = threading.Thread(target=watch, daemon=True)
        self.thread.start()

    def check(self):
        if self.failed:
            raise RuntimeError(self.failed)

    def finish(self):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=10)
        self.scan()


class Acceptance:
    def __init__(self, config, output):
        self.config = config
        self.output = Path(output)
        self.guard = IOGuard(self.output)
        self.phase = 'preflight'
        self.namespace = None
        self.run_id = secrets.token_hex(12)
        self.objects = {}
        self.automatic = {}
        self.endpoint_uid = None
        self.endpoint_uids = {}
        self.pod_targets = {}
        self.cross_resources = []
        self.node_uids = {}
        self.report = {'schema': 1, 'status': 'running', 'started_at': now(), 'checks': {},
                       'scope': {'mode': config.get('verification', {}).get('mode', 'selected-node'), 'node': config['node']['name'], 'configured_nodes': [n['name'] for n in config['nodes']], 'all_nodes_verified': False, 'network_all_nodes_verified': False, 'cross_node_tested': False, 'ha_tested': False, 'storage_requested': config['storage']['enabled'], 'storage_nodes': [config['node']['name']] if config['storage']['enabled'] else []},
                       'cleanup': {'status': 'not_started'}, 'io_guard': {'scope': 'selected_execution_node', 'status': 'not_started'}, 'remote_evidence_dir': str(self.output)}
        self.env = {k: v for k, v in os.environ.items() if not k.lower().endswith('_proxy') and k not in ('HARBOR_PASSWORD', 'SSHPASS', 'KUBECONFIG')}
        self.env.update(KUBECONFIG='/etc/kubernetes/admin.conf', NO_PROXY='*', no_proxy='*')
        self.kube = ['kubectl', '--kubeconfig=/etc/kubernetes/admin.conf', '--request-timeout=15s']

    def progress(self, phase):
        self.phase = phase
        print('[cluster-verify] ' + phase + ' node=' + self.config['node']['name'] + ' namespace=' + str(self.namespace), file=sys.stderr, flush=True)
        save(self.output / 'progress.json', {'at': now(), 'phase': phase, 'namespace': self.namespace})

    def command(self, args, input=None, timeout=35, check=True, sensitive=False):
        self.guard.check()
        data = input.encode() if isinstance(input, str) else input
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, start_new_session=True)
        deadline = time.monotonic() + timeout
        sent = False
        try:
            while True:
                self.guard.check()
                remaining = deadline - time.monotonic()
                require(remaining > 0, 'Command timed out in phase ' + self.phase)
                try:
                    out, err = process.communicate(input=data if not sent else None, timeout=min(0.5, remaining))
                    break
                except subprocess.TimeoutExpired:
                    sent = True
            self.guard.check()
        except BaseException:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.communicate(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                except ProcessLookupError:
                    pass
            raise
        result = {'returncode': process.returncode, 'stdout': out.decode(errors='replace'), 'stderr': err.decode(errors='replace')}
        if check:
            require(process.returncode == 0, ('Sensitive command failed' if sensitive else 'Command failed: ' + ' '.join(args[:4]) + ': ' + result['stderr'][-1500:]))
        return result

    def get(self, kind, name=None, namespace=None, missing=False):
        args = ['get', kind] + ([name] if name else []) + (['-n', namespace] if namespace else []) + (['--ignore-not-found'] if missing else []) + ['-o', 'json']
        raw = self.command(self.kube + args)['stdout']
        return json.loads(raw) if raw.strip() else None

    def persist_owned(self):
        save(self.output / 'owned-resources.json', {'namespace': self.namespace, 'run_id': self.run_id, 'objects': self.objects})

    def owned(self, kind, name):
        saved = self.objects[kind + '/' + name]
        obj = self.get(kind, name, saved.get('namespace'))
        require(obj['metadata']['uid'] == saved['uid'] and obj['metadata'].get('labels', {}).get(LABEL) == self.run_id, 'Owned resource UID/label changed: ' + kind + '/' + name)
        return obj

    def create(self, obj):
        meta = obj['metadata']
        require(meta['labels'].get(LABEL) == self.run_id, 'Missing run label')
        if obj['kind'] != 'Namespace':
            self.owned('Namespace', self.namespace)
            require(meta.get('namespace') == self.namespace, 'Creation crosses namespace boundary')
        created = json.loads(self.command(self.kube + ['create', '-f', '-', '-o', 'json'], input=json.dumps(obj))['stdout'])
        m = created['metadata']
        self.objects[created['kind'] + '/' + m['name']] = {'kind': created['kind'], 'name': m['name'], 'namespace': m.get('namespace'), 'uid': m['uid']}
        self.persist_owned()
        return created

    def meta(self, name):
        return {'name': name, 'namespace': self.namespace, 'labels': {LABEL: self.run_id}}

    def execute(self, name, args, input=None, check=True, timeout=35):
        self.owned('Pod', name)
        return self.command(self.kube + ['exec', '-i', '-n', self.namespace, name, '--'] + args, input=input, timeout=timeout, check=check)

    def wait_pod(self, name):
        deadline = time.monotonic() + 180
        while True:
            obj = self.owned('Pod', name)
            state = obj.get('status', {})
            if state.get('phase') == 'Running' and state.get('containerStatuses') and all(x.get('ready') for x in state['containerStatuses']):
                target = self.pod_targets.get(name, self.config['node'])
                require(obj['spec']['nodeName'] == target['name'], 'Pod scheduled on another node')
                image = self.config.get('images', {}).get(target['name'], self.config['image'])
                require(len(obj['spec']['containers']) == 1 and obj['spec']['containers'][0]['image'] == image and not obj['spec'].get('initContainers'), 'Admission changed the probe image/containers')
                require(obj['spec'].get('automountServiceAccountToken') is False and not any('hostPath' in v for v in obj['spec']['volumes']), 'Admission changed the probe credential/storage boundary')
                return obj
            require(time.monotonic() < deadline, 'Pod not ready: ' + name + ' ' + json.dumps(state.get('containerStatuses', []))[:1000])
            time.sleep(2)

    def pod(self, name, server=False, node=None, use_pvc=None):
        node = node or self.config['node']
        permitted = self.config.get('verification_nodes', [self.config['node']])
        require(node in permitted, 'Probe target is outside the verified node set')
        use_pvc = self.config['storage']['enabled'] if use_pvc is None else use_pvc
        require(not (server and use_pvc) or node['name'] == self.config['node']['name'], 'PVC verification must remain on selected execution node')
        self.pod_targets[name] = node
        volumes = [{'name': 'ca', 'configMap': {'name': 'public-ca'}}]
        mounts = [{'name': 'ca', 'mountPath': '/ca', 'readOnly': True}]
        if server:
            volumes.append({'name': 'data', 'persistentVolumeClaim': {'claimName': 'proof-volume'}} if use_pvc else {'name': 'data', 'emptyDir': {}})
            mounts.append({'name': 'data', 'mountPath': '/work'})
        metadata = self.meta(name)
        if server:
            metadata['labels']['rise.io/verification-role'] = 'server'
            metadata['labels']['rise.io/verification-server'] = 'primary' if name in ('server-a', 'server-b') else name
        command = ['sh', '-ec', 'exec sleep 36000']
        if server:
            command = ['sh', '-ec', 'until test -x /tmp/rise-tools/busybox; do sleep 1; done; exec /tmp/rise-tools/busybox httpd -f -p 8080 -h /work']
        return {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': metadata, 'spec': {
            'automountServiceAccountToken': False, 'restartPolicy': 'Never',
            'nodeSelector': {'kubernetes.io/hostname': node['name']},
            'tolerations': [{'key': key, 'operator': 'Exists', 'effect': 'NoSchedule'} for key in ('node-role.kubernetes.io/control-plane', 'node-role.kubernetes.io/master')],
            'securityContext': {'runAsUser': 1000, 'runAsGroup': 1000, 'fsGroup': 1000, 'seccompProfile': {'type': 'RuntimeDefault'}},
            'containers': [{'name': 'probe', 'image': self.config.get('images', {}).get(node['name'], self.config['image']), 'imagePullPolicy': 'IfNotPresent', 'command': command,
                            'securityContext': {'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}},
                            'resources': {'requests': {'cpu': '10m', 'memory': '32Mi'}, 'limits': {'cpu': '500m', 'memory': '256Mi'}}, 'volumeMounts': mounts}], 'volumes': volumes}}

    def mount(self, path):
        found = Path(path)
        while not found.exists() and found != found.parent:
            found = found.parent
        mounts = json.loads(self.command(['findmnt', '-J', '-T', str(found), '-o', 'TARGET,FSTYPE,UUID,MAJ:MIN'])['stdout'])['filesystems']
        require(len(mounts) == 1, 'Ambiguous local data mount')
        return mounts[0]

    def bundle(self):
        files = {'busybox': Path(shutil.which('busybox')), 'curl': Path(shutil.which('curl'))}
        arch = self.config['node']['arch']
        require(elf_info(files['busybox']) == (arch, None), 'BusyBox must be static and match the selected architecture')
        curl_arch, interpreter = elf_info(files['curl'])
        require(curl_arch == arch and interpreter, 'curl architecture/ELF loader differs')
        deps = self.command(['ldd', str(files['curl'])])['stdout']
        require('not found' not in deps, 'curl runtime library missing')
        for raw in re.findall(r'(?:=>\s+|^\s*)(/[^\s()]+)', deps, re.M):
            path = Path(raw)
            require(path.is_file() and elf_info(path)[0] == arch, 'Runtime library architecture differs')
            require(path.name not in files or files[path.name].resolve() == path.resolve(), 'Conflicting bundle filename')
            files[path.name] = path
        self.loader = Path(interpreter).name
        require(self.loader in files, 'ELF loader absent from verified curl dependency set')
        archive = io.BytesIO()
        self.bundle_manifest = []
        with tarfile.open(fileobj=archive, mode='w') as tar:
            for name, path in sorted(files.items()):
                require(re.fullmatch('[A-Za-z0-9_.+-]+', name), 'Unsafe bundle filename')
                content = path.read_bytes()
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(content), 0o500
                tar.addfile(info, io.BytesIO(content))
                self.bundle_manifest.append({'name': name, 'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
        self.bundle_bytes = archive.getvalue()

    def transfer(self, name):
        self.execute(name, ['sh', '-ec', 'umask 077; test ! -e /tmp/rise-tools; mkdir /tmp/rise-tools; tar -xf - -C /tmp/rise-tools'], input=self.bundle_bytes, timeout=90)
        checks = ''.join(x['sha256'] + '  /tmp/rise-tools/' + x['name'] + '\n' for x in self.bundle_manifest)
        self.execute(name, ['sha256sum', '-c', '-'], input=checks)
        command = ['env', '-i', 'PATH=/usr/bin:/bin', 'HOME=/tmp', 'LC_ALL=C', '/tmp/rise-tools/' + self.loader, '--library-path', '/tmp/rise-tools']
        listed = self.execute(name, command + ['--list', '/tmp/rise-tools/curl'])['stdout']
        libraries = re.findall(r'=>\s+(/[^\s()]+)', listed)
        require(libraries and all(Path(p).parent == Path('/tmp/rise-tools') and Path(p).name in {x['name'] for x in self.bundle_manifest} for p in libraries), 'curl loaded a library outside the verified bundle')
        self.execute(name, command + ['/tmp/rise-tools/curl', '--disable', '--version'])

    def curl(self, name, url, ca, check=True):
        return self.execute(name, ['env', '-i', 'PATH=/usr/bin:/bin', 'HOME=/tmp', 'LC_ALL=C', '/tmp/rise-tools/' + self.loader,
                                  '--library-path', '/tmp/rise-tools', '/tmp/rise-tools/curl', '--disable', '--noproxy', '*', '--proxy', '',
                                  '--cacert', '/ca/' + ca, '--fail', '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '10', url], check=check, timeout=20)

    def check_node(self, declared):
        node = self.get('node', declared['name'])
        require(node['metadata']['name'] == declared['name'] and node['metadata'].get('uid'), 'Live node identity missing')
        require(node['status']['nodeInfo']['architecture'] == declared['arch'], 'Live node architecture differs')
        require(any(x['type'] == 'InternalIP' and x['address'] == declared['ip'] for x in node['status']['addresses']), 'Live node address differs')
        conditions = {c['type']: c['status'] for c in node['status']['conditions']}
        require(conditions.get('Ready') == 'True' and all(conditions.get(c) == 'False' for c in ('MemoryPressure', 'DiskPressure', 'PIDPressure')), 'Verification node is not Ready or has pressure: ' + declared['name'])
        uid = node['metadata']['uid']
        require(declared['name'] not in self.node_uids or self.node_uids[declared['name']] == uid, 'Verification node UID changed')
        self.node_uids[declared['name']] = uid
        return node

    def preflight(self):
        require(os.geteuid() == 0, 'Root on the selected control-plane node is required')
        for tool in ('kubectl', 'journalctl', 'findmnt', 'curl', 'busybox', 'ldd', 'openssl'):
            require(shutil.which(tool), 'Missing offline acceptance prerequisite: ' + tool)
        require(sha(self.output / 'harbor-ca.pem') == self.config['harbor_ca_sha256'], 'Public Harbor CA changed during upload')
        for declared in self.config.get('verification_nodes', [self.config['node']]):
            self.check_node(declared)
        self.report['scope']['network_nodes_requested'] = list(self.node_uids)
        local = json.loads(self.command(['ip', '-j', 'addr', 'show'])['stdout'])
        require(any(a.get('local') == self.config['node']['ip'] for interface in local for a in interface.get('addr_info', [])), 'Execution host does not own the selected node IP')
        require(self.get('namespace', 'kube-system')['metadata']['uid'] == self.config['cluster_uid'], 'Live cluster UID differs')
        self.bundle()
        raw = self.command(self.kube + ['config', 'view', '--raw', '--minify', '-o', 'json'], sensitive=True)['stdout']
        cfg = json.loads(raw)
        cluster, user = cfg['clusters'][0]['cluster'], cfg['users'][0]['user']
        require(not cluster.get('insecure-skip-tls-verify') and not cluster.get('proxy-url'), 'Unsafe kubeconfig TLS/proxy settings')
        endpoint = urlsplit(cluster['server'])
        require(endpoint.scheme == 'https' and not endpoint.username and not endpoint.password and endpoint.path in ('', '/') and not endpoint.query and not endpoint.fragment, 'Invalid API endpoint')
        require(endpoint.hostname == self.config['api']['host'] and endpoint.port == self.config['api']['port'], 'API endpoint does not match configuration')
        require(set(user) == {'client-certificate-data', 'client-key-data'}, 'Unsupported administrator authentication mode')
        self.kubernetes_ca = base64.b64decode(cluster['certificate-authority-data'], validate=True).decode()
        self.context = ssl.create_default_context(cadata=self.kubernetes_ca)
        descriptors = []
        try:
            for key in ('client-certificate-data', 'client-key-data'):
                fd = os.memfd_create('rise-cluster-verification', os.MFD_CLOEXEC)
                descriptors.append(fd)
                with os.fdopen(os.dup(fd), 'wb') as stream:
                    stream.write(base64.b64decode(user[key], validate=True))
            self.context.load_cert_chain('/proc/self/fd/' + str(descriptors[0]), '/proc/self/fd/' + str(descriptors[1]))
        finally:
            for fd in descriptors:
                os.close(fd)
        self.endpoint = endpoint
        self.command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', '/dev/null', '-out', str(self.output / 'untrusted-ca.pem'), '-days', '1', '-subj', '/CN=rise-verification-untrusted'])
        self.baseline = {'pvs': {p['metadata']['name']: p['metadata']['uid'] for p in self.get('pv')['items']}, 'base_children': []}
        if self.config['storage']['enabled']:
            sc = self.get('storageclass', 'openebs-hostpath')
            require((sc['provisioner'], sc['reclaimPolicy'], sc['volumeBindingMode']) == ('openebs.io/local', 'Delete', 'WaitForFirstConsumer'), 'Unsupported local StorageClass semantics')
            base = Path(self.config['storage']['path'])
            require(base.is_absolute() and base.resolve() == base, 'Local storage path is redirected')
            require(storage_base(sc['metadata']['annotations']['cas.openebs.io/config']) == str(base), 'StorageClass BasePath differs from deployment configuration')
            self.baseline['base_children'] = sorted(str(p.resolve()) for p in base.iterdir()) if base.exists() else []
            self.baseline['mount'] = self.mount(base)
            if self.config['node']['data_mode'] != 'native':
                require(self.baseline['mount']['target'] == self.config['node']['data_path'], 'Local PV is not on the declared data mount')
            require(self.baseline['mount']['fstype'] in ('ext4', 'xfs'), 'Unsupported local PV filesystem')
            self.baseline['storageclass_uid'] = sc['metadata']['uid']
        save(self.output / 'baseline.json', self.baseline)
        self.report['tool_bundle'] = {'architecture': self.config['node']['arch'], 'files': self.bundle_manifest, 'package_installation': False, 'credentials_in_pods': False}
        self.report['io_guard']['unmonitored_nodes'] = [n for n in self.node_uids if n != self.config['node']['name']]

    def prepare(self):
        self.namespace = 'rise-verify-' + secrets.token_hex(8)
        require(self.get('namespace', self.namespace, missing=True) is None, 'Fresh verification namespace already exists')
        self.create({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': self.namespace, 'labels': {LABEL: self.run_id}}})
        self.create({'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': self.meta('public-ca'), 'data': {
            'harbor.crt': (self.output / 'harbor-ca.pem').read_text(), 'kubernetes.crt': self.kubernetes_ca, 'untrusted.crt': (self.output / 'untrusted-ca.pem').read_text()}})
        self.create(self.pod('client'))
        self.wait_pod('client')
        self.transfer('client')
        self.execute('client', ['sh', '-ec', 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token'])
        for kind, name in (('ConfigMap', 'kube-root-ca.crt'), ('ServiceAccount', 'default')):
            obj = self.get(kind, name, self.namespace)
            if kind == 'ConfigMap':
                require(obj.get('data') == {'ca.crt': self.kubernetes_ca}, 'Unexpected namespace CA bundle')
            else:
                require(not obj.get('secrets') and not obj.get('imagePullSecrets'), 'Unexpected default ServiceAccount credentials')
            self.automatic[(kind, name)] = obj['metadata']['uid']

    def network(self, client='client'):
        proof = {}
        prefix = 'dns-' if client == 'client' else 'dns-' + client + '-'
        resolv = self.execute(client, ['cat', '/etc/resolv.conf'])['stdout']
        searches = [v for line in resolv.splitlines() if line.startswith('search ') for v in line.split()[1:]]
        suffix = [s[len(self.namespace) + 5:] for s in searches if s.startswith(self.namespace + '.svc.')]
        require(len(suffix) == 1 and re.fullmatch('[A-Za-z0-9.-]+', suffix[0]), 'Cannot determine cluster DNS domain')
        require(not hasattr(self, 'dns_domain') or self.dns_domain == suffix[0], 'Cluster DNS domain differs across probe Pods')
        self.dns_domain = suffix[0]
        standard = 'kubernetes.default.svc.' + self.dns_domain
        api_ip = self.get('service', 'kubernetes', 'default')['spec']['clusterIP']
        services = self.get('services', namespace='kube-system')['items']
        dns = [s['spec']['clusterIP'] for s in services if s['metadata'].get('labels', {}).get('k8s-app') == 'kube-dns']
        require(len(dns) == 1, 'Cannot uniquely identify CoreDNS Service')
        resolvers = list(dict.fromkeys([None, *[line.split()[1] for line in resolv.splitlines() if line.startswith('nameserver ')], dns[0]]))
        observations = []
        expected_api_ips = self.config['api'].get('ips') or self.config['api']['ip']
        domains = [(standard, api_ip), (self.config['harbor']['host'], self.config['harbor']['ip']), (self.config['api']['host'], expected_api_ips)]
        for server in resolvers:
            for domain, expected in domains:
                # An IP literal is not a DNS name. Querying it makes some
                # resolvers answer NXDOMAIN for AAAA, which is not a failure.
                try:
                    ipaddress.ip_address(domain)
                except ValueError:
                    literal_ip = False
                else:
                    literal_ip = True
                if literal_ip:
                    require(domain == expected, 'Literal API/Harbor IP differs from configuration')
                    observations.append({'resolver': server or 'pod-default', 'domain': domain, 'addresses': [domain], 'literal_ip': True})
                    save(self.output / (prefix + str(len(observations)) + '.json'), {'resolver': server or 'pod-default', 'domain': domain, 'attempts': [{'at': now(), 'addresses': [domain], 'status': 'passed', 'literal_ip': True}]})
                    continue
                deadline = time.monotonic() + 90
                attempts = []
                while True:
                    addresses, failures = [], []
                    for family in ('A', 'AAAA'):
                        args = ['/tmp/rise-tools/busybox', 'nslookup', '-type=' + family, domain] + ([server] if server else [])
                        answer = self.execute(client, args, check=False)
                        if answer['returncode'] != 0:
                            failures.append(family + ': ' + answer['stdout'][-500:] + answer['stderr'][-500:])
                        addresses.extend(dns_addresses(answer['stdout']))
                    try:
                        require(not failures, 'DNS query failed: ' + '; '.join(failures))
                        validate_addresses(addresses, expected)
                        attempts.append({'at': now(), 'addresses': sorted(set(addresses)), 'status': 'passed'})
                        break
                    except RuntimeError as error:
                        attempts.append({'at': now(), 'addresses': sorted(set(addresses)), 'status': 'failed', 'error': str(error)})
                        save(self.output / (prefix + 'attempts.json'), {'resolver': server or 'pod-default', 'domain': domain, 'attempts': attempts, 'completed_queries': observations})
                        require(time.monotonic() < deadline, 'DNS acceptance timed out for ' + domain + ' via ' + str(server) + ': ' + str(error))
                        time.sleep(3)
                observations.append({'resolver': server or 'pod-default', 'domain': domain, 'addresses': sorted(set(addresses))})
                save(self.output / (prefix + str(len(observations)) + '.json'), {'resolver': server or 'pod-default', 'domain': domain, 'attempts': attempts})
        proof['dns'] = {'status': 'passed', 'queries': observations}
        proof['api_alias'] = {'status': 'passed', 'domain': self.config['api']['host'], 'expected_ip': self.config['api']['ip'], 'loopback_rejected': True}
        for name, authority in [('standard', standard), ('configured_alias', self.config['api']['host'] + ':' + str(self.config['api']['port']))]:
            response = self.curl(client, 'https://' + authority + '/version', 'kubernetes.crt')
            require(json.loads(response['stdout'])['gitVersion'] == self.config['version'], 'Pod API version differs')
        proof['api_tls'] = {'status': 'passed', 'standard_service': standard, 'configured_alias': self.config['api']['host'], 'authentication': 'none', 'certificate_verification': True}
        harbor = 'https://' + self.config['harbor']['host'] + ':' + str(self.config['harbor']['port']) + '/api/v2.0/health'
        response = self.curl(client, harbor, 'harbor.crt')
        require(json.loads(response['stdout'])['status'] == 'healthy', 'Pod Harbor health failed')
        wrong = self.curl(client, harbor, 'untrusted.crt', check=False)
        require(wrong['returncode'] == 60, 'Wrong-CA test did not fail with certificate-verification error')
        proof['harbor_tls'] = {'status': 'passed', 'certificate_verification': True, 'wrong_ca_exit': 60}

        if client == 'client':
            self.report['checks'].update(proof)
        return proof

    def pv(self):
        claim = self.owned('PersistentVolumeClaim', 'proof-volume')
        require(claim.get('status', {}).get('phase') == 'Bound', 'PVC is not Bound')
        volume = self.get('pv', claim['spec']['volumeName'])
        path = validate_pv(volume, claim, self.namespace, self.config['storage']['path'], self.config['node']['name'], self.baseline)
        require(Path(path).is_dir() and self.mount(path) == self.baseline['mount'], 'PV filesystem changed')
        require(self.get('storageclass', 'openebs-hostpath')['metadata']['uid'] == self.baseline['storageclass_uid'], 'StorageClass UID changed')
        return {'pvc_uid': claim['metadata']['uid'], 'pv_uid': volume['metadata']['uid'], 'pv_name': volume['metadata']['name'], 'path': path, 'mount': self.baseline['mount']}

    def http(self, name, payload, client='client', service_name='proof-service'):
        pod = self.owned('Pod', name)
        service = self.owned('Service', service_name)
        addresses = [pod['status']['podIP'], service['spec']['clusterIP'], service_name + '.' + self.namespace + '.svc.' + self.dns_domain]
        results = []
        for address in addresses:
            deadline = time.monotonic() + 40
            while True:
                answer = self.execute(client, ['/tmp/rise-tools/busybox', 'wget', '-q', '-O', '-', 'http://' + address + ':8080/proof.txt'], check=False, timeout=10)
                if answer['returncode'] == 0 and answer['stdout'] == payload:
                    break
                require(time.monotonic() < deadline, 'HTTP payload mismatch/unreachable: ' + address)
                time.sleep(1)
            results.append({'address': address, 'matched': True, 'sha256': hashlib.sha256(payload.encode()).hexdigest()})
        return results

    def storage_service(self):
        enabled = self.config['storage']['enabled']
        if enabled:
            self.create({'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim', 'metadata': self.meta('proof-volume'), 'spec': {'storageClassName': 'openebs-hostpath', 'accessModes': ['ReadWriteOnce'], 'resources': {'requests': {'storage': '1Gi'}}}})
        self.create(self.pod('server-a', server=True))
        first = self.wait_pod('server-a')
        self.volume = self.pv() if enabled else None
        self.transfer('server-a')
        payload = 'rise-verification ' + self.run_id + ' ' + secrets.token_hex(24) + '\n'
        self.service_payload = payload
        checksum = hashlib.sha256(payload.encode()).hexdigest()
        self.execute('server-a', ['sh', '-ec', 'umask 077; test ! -e /work/proof.txt; cat > /work/proof.txt; sync'], input=payload)
        require(self.execute('server-a', ['sha256sum', '/work/proof.txt'])['stdout'].split()[0] == checksum, 'Pod file SHA differs')
        if enabled:
            require(sha(Path(self.volume['path']) / 'proof.txt') == checksum, 'Host/PVC file SHA differs')
        self.create({'apiVersion': 'v1', 'kind': 'Service', 'metadata': self.meta('proof-service'), 'spec': {'type': 'ClusterIP', 'selector': {LABEL: self.run_id, 'rise.io/verification-role': 'server', 'rise.io/verification-server': 'primary'}, 'ports': [{'name': 'http', 'port': 8080, 'targetPort': 8080}]}})
        self.report['checks']['service'] = {'status': 'passed', 'initial': self.http('server-a', payload)}
        if enabled:
            self.progress('pvc-pod-recreation')
            require(self.pv() == self.volume, 'PV changed before Pod recreation')
            self.delete('Pod', 'server-a')
            self.wait_absent('Pod', 'server-a')
            self.create(self.pod('server-b', server=True))
            second = self.wait_pod('server-b')
            require(second['metadata']['uid'] != first['metadata']['uid'], 'Replacement Pod UID unchanged')
            require(self.pv() == self.volume, 'PVC/PV identity changed after Pod recreation')
            self.transfer('server-b')
            require(self.execute('server-b', ['sha256sum', '/work/proof.txt'])['stdout'].split()[0] == checksum and sha(Path(self.volume['path']) / 'proof.txt') == checksum, 'File changed after Pod recreation')
            self.report['checks']['service']['after_recreation'] = self.http('server-b', payload)
            self.report['checks']['storage'] = {'status': 'passed', 'volume': self.volume, 'sha256_before': checksum, 'sha256_after': checksum, 'file_rewritten': False, 'first_pod_uid': first['metadata']['uid'], 'replacement_pod_uid': second['metadata']['uid'], 'scope': 'same-node Pod recreation; no reboot, HA or capacity-quota test'}
        else:
            self.report['checks']['storage'] = {'status': 'skipped', 'reason': 'LOCAL_STORAGE=false; Service uses an ephemeral emptyDir and PVC persistence was not tested'}

    def cross_node_network(self):
        if self.config.get('verification', {}).get('mode', 'selected-node') != 'cross-node':
            return
        nodes = self.config['verification_nodes']
        require(len(nodes) >= 2 and len({n['name'] for n in nodes}) == len(nodes), 'Cross-node participant set is invalid')
        primary = self.config['node']['name']
        server = 'server-b' if self.config['storage']['enabled'] else 'server-a'
        participants = {primary: {'client': 'client', 'server': server, 'service': 'proof-service', 'payload': self.service_payload}}
        network_checks = {primary: {k: copy.deepcopy(self.report['checks'][k]) for k in ('dns', 'api_alias', 'api_tls', 'harbor_tls')}}
        for index, node in enumerate(nodes):
            self.check_node(node)
            if node['name'] == primary:
                continue
            self.progress('cross-node-network/node-' + node['name'])
            pod_name = 'peer-' + str(index)
            service_name = 'peer-service-' + str(index)
            self.create(self.pod(pod_name, server=True, node=node, use_pvc=False))
            self.cross_resources.append(('Pod', pod_name))
            self.wait_pod(pod_name)
            self.transfer(pod_name)
            self.execute(pod_name, ['sh', '-ec', 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token'])
            payload = 'rise-cross-node ' + self.run_id + ' ' + node['name'] + ' ' + secrets.token_hex(24) + '\n'
            self.execute(pod_name, ['sh', '-ec', 'umask 077; test ! -e /work/proof.txt; cat > /work/proof.txt'], input=payload)
            require(self.execute(pod_name, ['sha256sum', '/work/proof.txt'])['stdout'].split()[0] == hashlib.sha256(payload.encode()).hexdigest(), 'Cross-node server file SHA differs')
            self.create({'apiVersion': 'v1', 'kind': 'Service', 'metadata': self.meta(service_name), 'spec': {'type': 'ClusterIP', 'selector': {LABEL: self.run_id, 'rise.io/verification-role': 'server', 'rise.io/verification-server': pod_name}, 'ports': [{'name': 'http', 'port': 8080, 'targetPort': 8080}]}})
            self.cross_resources.append(('Service', service_name))
            participants[node['name']] = {'client': pod_name, 'server': pod_name, 'service': service_name, 'payload': payload}
            network_checks[node['name']] = self.network(pod_name)
            save(self.output / ('network-' + pod_name + '.json'), network_checks[node['name']])
        pairs = []
        for source in nodes:
            for target in nodes:
                if source['name'] == target['name']:
                    continue
                self.progress('cross-node-network/' + source['name'] + '->' + target['name'])
                origin, destination = participants[source['name']], participants[target['name']]
                client = self.owned('Pod', origin['client'])
                server = self.owned('Pod', destination['server'])
                require(client['spec']['nodeName'] == source['name'] and server['spec']['nodeName'] == target['name'], 'Cross-node Pod placement changed')
                require(client['spec']['nodeName'] != server['spec']['nodeName'], 'Cross-node pair is actually same-node')
                self.check_node(source)
                self.check_node(target)
                result = self.http(destination['server'], destination['payload'], client=origin['client'], service_name=destination['service'])
                pairs.append({'source_node': source['name'], 'target_node': target['name'], 'client_pod': origin['client'], 'server_pod': destination['server'], 'client_uid': client['metadata']['uid'], 'server_uid': server['metadata']['uid'], 'status': 'passed', 'paths': result})
                save(self.output / 'cross-node-progress.json', {'network_checks': network_checks, 'pairs': pairs})
        for node in nodes:
            self.check_node(node)
        require(len(pairs) == len(nodes) * (len(nodes) - 1), 'Cross-node pair matrix is incomplete')
        self.report['checks']['cross_node'] = {'status': 'passed', 'nodes': [n['name'] for n in nodes], 'node_uids': dict(self.node_uids), 'network_checks': network_checks, 'pairs': pairs, 'coverage': 'Every directed pair: Pod IP, Service IP and Service FQDN; local PVC remains on selected control-plane node'}
        self.report['scope'].update(network_all_nodes_verified=True, cross_node_tested=True)

    def delete_request(self, kind, name):
        resources = {'Namespace': 'namespaces', 'Pod': 'pods', 'Service': 'services', 'ConfigMap': 'configmaps', 'PersistentVolumeClaim': 'persistentvolumeclaims'}
        require(kind in resources, 'Unsupported deletion kind')
        self.owned(kind, name)
        entry = self.objects[kind + '/' + name]
        require(re.fullmatch('[a-z0-9][a-z0-9-]*', name), 'Unsafe deletion name')
        if kind == 'Namespace':
            require(name == self.namespace and entry.get('namespace') is None, 'Wrong namespace deletion')
        else:
            require(entry.get('namespace') == self.namespace, 'Deletion crosses namespace boundary')
        path = '/api/v1' + ('' if kind == 'Namespace' else '/namespaces/' + quote(self.namespace, safe='')) + '/' + resources[kind] + '/' + quote(name, safe='')
        options = {'apiVersion': 'v1', 'kind': 'DeleteOptions', 'preconditions': {'uid': entry['uid']}}
        if kind == 'Pod':
            options['gracePeriodSeconds'] = 10
        return path, options

    def delete(self, kind, name):
        path, options = self.delete_request(kind, name)
        self.guard.check()
        connection = http.client.HTTPSConnection(self.endpoint.hostname, self.endpoint.port, context=self.context, timeout=10)
        try:
            connection.request('DELETE', path, body=json.dumps(options).encode(), headers={'Content-Type': 'application/json'})
            response = connection.getresponse()
            status, body = response.status, response.read(16384)
        finally:
            connection.close()
        self.guard.check()
        require(status in (200, 202), 'UID-conditional DELETE failed: ' + str(status) + ' ' + body.decode(errors='replace')[:300])
        self.report.setdefault('deletions', []).append({'kind': kind, 'name': name, 'uid': options['preconditions']['uid'], 'status': status})
        save(self.output / 'deletions.json', self.report['deletions'])

    def wait_absent(self, kind, name, seconds=180):
        saved = self.objects[kind + '/' + name]
        deadline = time.monotonic() + seconds
        while True:
            obj = self.get(kind, name, saved.get('namespace'), missing=True)
            if obj is None:
                return
            require(obj['metadata']['uid'] == saved['uid'], 'Resource replaced during deletion wait')
            require(time.monotonic() < deadline, 'Resource deletion timed out: ' + kind + '/' + name)
            time.sleep(2)

    def capture_endpoint(self, name='proof-service'):
        endpoint = self.get('endpoints', name, self.namespace, missing=True)
        if endpoint is None:
            return
        service = self.owned('Service', name)
        meta = endpoint['metadata']
        require(meta.get('labels', {}).get(LABEL) == self.run_id and meta['labels'].get('endpoints.kubernetes.io/managed-by') == 'endpoint-controller', 'Unexpected legacy endpoints identity')
        require(meta['creationTimestamp'] >= service['metadata']['creationTimestamp'], 'Endpoints predates owned Service')
        addresses = [a for subset in endpoint.get('subsets', []) for a in subset.get('addresses', [])]
        require(addresses, 'Legacy endpoints has no target')
        for address in addresses:
            ref = address.get('targetRef', {})
            require(ref.get('kind') == 'Pod' and ref.get('namespace') == self.namespace and 'Pod/' + ref.get('name', '') in self.objects, 'Unrelated endpoint target')
            pod = self.owned('Pod', ref['name'])
            require(ref['uid'] == pod['metadata']['uid'] and address['ip'] == pod['status']['podIP'], 'Endpoint target UID/IP differs')
            selector = service['spec']['selector']
            require(selector.get(LABEL) == self.run_id and selector.get('rise.io/verification-server'), 'Service lacks an isolated owned server selector')
            require(all(pod['metadata'].get('labels', {}).get(k) == v for k, v in selector.items()), 'Endpoint targets another owned service probe')
        for subset in endpoint['subsets']:
            require(subset.get('ports') == [{'name': 'http', 'port': 8080, 'protocol': 'TCP'}] and not subset.get('notReadyAddresses'), 'Unexpected endpoint ports or not-ready targets')
        self.endpoint_uids[name] = meta['uid']
        if name == 'proof-service':
            self.endpoint_uid = meta['uid']
        save(self.output / ('controller-endpoint-' + name + '.json'), {'uid': meta['uid'], 'service_uid': service['metadata']['uid']})

    def inventory(self, allow_tests=True):
        allowed = dict(self.automatic)
        if allow_tests:
            allowed.update({(obj['kind'], obj['name']): obj['uid'] for obj in self.objects.values() if obj.get('namespace') == self.namespace})
        uids = {x['uid'] for x in self.objects.values()}
        resources = self.command(self.kube + ['api-resources', '--verbs=list', '--namespaced=true', '-o', 'name'])['stdout'].splitlines()
        require('pods' in resources and 'secrets' in resources, 'Incomplete API resource discovery')
        found = []
        for resource in resources:
            for obj in self.get(resource, namespace=self.namespace)['items']:
                kind, meta = obj['kind'], obj['metadata']
                if kind == 'Event':
                    require((obj.get('involvedObject') or obj.get('regarding') or {}).get('uid') in uids, 'Foreign event blocks namespace cleanup')
                elif kind == 'Endpoints' and allow_tests:
                    expected = self.endpoint_uids.get(meta['name'], self.endpoint_uid if meta['name'] == 'proof-service' else None)
                    require(expected and meta['uid'] == expected and meta.get('labels', {}).get(LABEL) == self.run_id, 'Foreign legacy endpoints blocks cleanup')
                elif kind == 'EndpointSlice' and allow_tests:
                    services = {x['uid'] for x in self.objects.values() if x['kind'] == 'Service' and x.get('namespace') == self.namespace}
                    require(any(x.get('kind') == 'Service' and x.get('uid') in services for x in meta.get('ownerReferences', [])), 'Foreign EndpointSlice blocks cleanup')
                else:
                    require(allowed.get((kind, meta['name'])) == meta['uid'], 'Foreign/replaced resource blocks namespace cleanup: ' + kind + '/' + meta['name'])
                found.append({'resource': resource, 'kind': kind, 'name': meta['name'], 'uid': meta['uid']})
        return found

    def cleanup(self):
        for obj in self.objects.values():
            if obj['kind'] == 'Service':
                self.capture_endpoint(obj['name'])
        save(self.output / 'namespace-before-cleanup.json', self.inventory())
        enabled = self.config['storage']['enabled']
        if enabled:
            require(self.pv() == self.volume, 'PV changed before cleanup')
        for kind, name in self.cross_resources + [('Pod', 'server-b' if enabled else 'server-a'), ('Pod', 'client'), ('Service', 'proof-service'), ('ConfigMap', 'public-ca')]:
            self.delete(kind, name)
            self.wait_absent(kind, name)
        if enabled:
            require(self.pv() == self.volume, 'PV changed before PVC deletion')
            self.delete('PersistentVolumeClaim', 'proof-volume')
            self.wait_absent('PersistentVolumeClaim', 'proof-volume')
            deadline = time.monotonic() + 240
            while True:
                pv = self.get('pv', self.volume['pv_name'], missing=True)
                if pv is None and not os.path.lexists(self.volume['path']):
                    break
                if pv:
                    require(pv['metadata']['uid'] == self.volume['pv_uid'], 'PV replaced during automatic reclaim')
                require(time.monotonic() < deadline, 'Provisioner has not reclaimed the owned volume; no forced cleanup attempted')
                time.sleep(2)
        save(self.output / 'namespace-before-delete.json', self.inventory(allow_tests=False))
        self.delete('Namespace', self.namespace)
        self.wait_absent('Namespace', self.namespace)
        current = {p['metadata']['name']: p['metadata']['uid'] for p in self.get('pv')['items']}
        require(all(current.get(name) == uid for name, uid in self.baseline['pvs'].items()), 'Pre-existing PV changed')
        require(all(Path(p).exists() for p in self.baseline['base_children']), 'Pre-existing local PV base entry disappeared')
        self.report['cleanup'] = {'status': 'passed', 'namespace_absent': True, 'test_pv_absent': True if enabled else 'not_applicable', 'test_directory_absent': True if enabled else 'not_applicable', 'manual_directory_removal': False, 'forced_finalizer_removal': False, 'existing_pvs_preserved': True}

    def run(self):
        try:
            require(not (self.output / 'result.json').exists(), 'Refuse to reuse a previous verification directory')
            self.guard.start()
            for phase, operation in [('preflight', self.preflight), ('create-isolated-resources', self.prepare), ('pod-dns-tls', self.network), ('pod-service-pvc', self.storage_service), ('cross-node-network', self.cross_node_network), ('cleanup-owned-resources', self.cleanup)]:
                self.progress(phase)
                operation()
                save(self.output / 'checkpoint.json', self.report)
            self.guard.finish()
            self.report.update(status='passed', resources_retained=False)
            self.report['io_guard'].update(status='passed', new_errors=0)
        except BaseException as error:
            self.guard.stop.set()
            self.report.update(status='failed', phase=self.phase, error=str(error), resources_retained=bool(self.namespace), namespace=self.namespace)
            self.report['io_guard'].update(status='failed' if self.guard.failed else 'incomplete', error=self.guard.failed)
            print('[cluster-verify ERROR] ' + self.phase + ': ' + str(error) + '; resources retained; evidence=' + str(self.output), file=sys.stderr, flush=True)
        self.report.update(finished_at=now(), namespace=self.namespace)
        save(self.output / 'result.json', self.report)
        return self.report


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    cfg = sub.add_parser('config')
    for name in ('base', 'registry-receipt', 'node-receipt', 'identity-dir', 'ca', 'output'):
        cfg.add_argument('--' + name, required=True)
    run = sub.add_parser('run')
    run.add_argument('--config', required=True)
    run.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    if args.action == 'config':
        try:
            build_config(args)
        except Exception as error:
            save(Path(args.output).parent / 'cluster-verify-evidence.json', {'schema': 1, 'status': 'failed', 'phase': 'controller-evidence-preflight', 'error': str(error), 'resources_retained': False, 'cleanup': {'status': 'not_started'}})
            raise
        return 0
    acceptance = Acceptance(json.loads(Path(args.config).read_text()), args.output_dir)
    result = acceptance.run()
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('[cluster-verify ERROR] ' + str(error), file=sys.stderr)
        sys.exit(1)
