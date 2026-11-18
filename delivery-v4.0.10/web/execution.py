"""Privileged, single-operator deployment jobs. No HTTP or arbitrary commands.

The operator is explicitly authorized to administer the configured nodes. This
broker is not a multi-tenant sandbox: trusted installation media and protected
administrator-installed code are prerequisites. Tests inject a fake runner.
"""
import base64
from collections import deque
import copy
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import socket
import stat
import subprocess
import threading
import time
import unicodedata
import uuid

from artifact_digest import resolve as resolve_artifact_sha
from config_model import ModelError, default_config, export_env, normalize_config

MAX_REQUEST = 256 * 1024
MAX_RESPONSE = 1024 * 1024
MAX_LOG = 4 * 1024 * 1024
HEAD_LOG = 1 * 1024 * 1024
TAIL_LOG = MAX_LOG - HEAD_LOG - 256
MAX_LOG_READ = 64 * 1024
LOG_LIMIT_MARKER = '[日志保留上限已达到；后续输出不再保存]\n'.encode('utf-8')
ACTIVE = frozenset(('queued', 'running', 'stop_requested'))
UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z')
CLUSTER = re.compile(r'[a-z][a-z0-9-]{0,62}\Z')


class ExecutionError(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message
        super().__init__(message)


def fail(status, code, message):
    raise ExecutionError(status, code, message)


def shape(body, keys):
    if not isinstance(body, dict) or set(body) != set(keys):
        fail(400, 'invalid_request', '请求字段不完整或包含不支持的字段。')


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate field')
            result[key] = value
        return result
    def invalid(_):
        raise ValueError('nonfinite number')
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def private_write(path, payload):
    """Write only beneath an already protected directory, without link following."""
    path = Path(path)
    tmp = path.with_name('.' + path.name + '.' + secrets.token_hex(12))
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(tmp), str(path))
        directory = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if tmp.exists():
            tmp.unlink()


def protected_path(path, trusted_uid=0, directory=False, absent=False):
    """lstat every component; no symlinks or writable ancestors.

    Non-root trust is an injectable Python-test facility, never a CLI option.
    Only that facility permits the root-owned sticky /tmp ancestor.
    """
    path = Path(os.path.abspath(str(path)))
    current = Path(path.anchor)
    parts = path.parts[1:]
    missing = False
    for index, part in enumerate(parts):
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if absent:
                missing = True
                continue
            fail(400, 'untrusted_path', '执行输入不存在或不属于受保护的管理员路径。')
        if missing or stat.S_ISLNK(info.st_mode):
            fail(400, 'untrusted_path', '执行路径含链接或不安全目录。')
        last = index == len(parts) - 1
        expected_directory = not last or directory
        if expected_directory and not stat.S_ISDIR(info.st_mode):
            fail(400, 'untrusted_path', '执行路径的目录类型无效。')
        if not expected_directory and not stat.S_ISREG(info.st_mode):
            fail(400, 'untrusted_path', '执行输入必须是普通文件。')
        # Namespace sandboxes may map /tmp's owner to nobody. Production has
        # trusted_uid=0 and never takes this test-only sticky-directory branch.
        test_tmp = trusted_uid != 0 and current == Path('/tmp') and info.st_mode & stat.S_ISVTX
        if not test_tmp and (info.st_uid not in (0, trusted_uid) or info.st_mode & 0o022):
            fail(400, 'untrusted_path', '执行路径必须由管理员控制，且禁止组或其他用户写入。')
    return path


def protected_directory(path, trusted_uid=0):
    path = protected_path(path, trusted_uid, directory=True, absent=True)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)
    protected_path(path, trusted_uid, directory=True)
    if path.stat().st_uid != trusted_uid or path.stat().st_mode & 0o077:
        fail(400, 'untrusted_directory', '执行器数据和工作目录必须由执行器所有，权限为 0700。')
    return path


def managed_root(path, kind, trusted_uid=0):
    path = protected_directory(path, trusted_uid)
    marker = path / '.rise-web-executor-root'
    expected = {'schema': 1, 'kind': kind}
    if marker.exists() or marker.is_symlink():
        protected_path(marker, trusted_uid)
        try:
            if marker.stat().st_size > 256 or strict_json(marker.read_text(encoding='utf-8')) != expected:
                raise ValueError('wrong marker')
        except (OSError, ValueError):
            fail(400, 'invalid_root_marker', '执行器专用目录标记不匹配，请管理员核查。')
    else:
        if any(path.iterdir()):
            fail(400, 'nonempty_root', '首次启动只接受新建或空的专用目录，不接管未知内容。')
        private_write(marker, encoded(expected))
    return path


def project_digest(project, trusted_uid=0):
    """Hash execution sources and validate every static input's ownership.

    Large archives are verified by the CLI's mandatory artifact SHA preflight;
    their inode metadata is bound here. Runtime directories are not source.
    """
    project = protected_path(project, trusted_uid, directory=True)
    digest = hashlib.sha256()
    skipped = {'runs', 'state', '.git', '__pycache__', '.pytest_cache'}
    for name in ('runs', 'state'):
        runtime = project / name
        if runtime.exists() or runtime.is_symlink():
            protected_path(runtime, trusted_uid, directory=True)
            if runtime.stat().st_uid != trusted_uid or runtime.stat().st_mode & 0o077:
                fail(400, 'untrusted_runtime', '发布目录已有运行根必须为执行器所有的 0700 普通目录。')
    count = 0
    for directory, dirs, files in os.walk(str(project), followlinks=False):
        dirs[:] = sorted(name for name in dirs if name not in skipped)
        for name in dirs:
            protected_path(Path(directory) / name, trusted_uid, directory=True)
        for name in sorted(files):
            path = protected_path(Path(directory) / name, trusted_uid)
            info = path.stat()
            digest.update(str(path.relative_to(project)).encode('utf-8') + b'\0')
            digest.update(('%s:%s:%s:%s:%s' % (info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode, info.st_uid)).encode())
            if not name.endswith(('.tgz', '.tar.gz', '.iso', '.zip', '.pyc')):
                with path.open('rb') as source:
                    for block in iter(lambda: source.read(1024 * 1024), b''):
                        digest.update(block)
            count += 1
    if not count or not (project / 'deploy.sh').is_file():
        fail(400, 'invalid_project', '受信任发布目录缺少 deploy.sh。')
    return digest.hexdigest()


class JobLog:
    """Line-oriented bytes decoder with optional exact credential masking.

    Arbitrary log text is not heuristically redacted, preserving diagnostic
    clarity; when submitted secret values are supplied, their exact literal
    occurrences are masked with [REDACTED] before persistence.
    """
    def __init__(self, secrets=None):
        self.pending = bytearray()
        self.discarding = False
        self.max_line = 32 * 1024
        self.secrets = sorted({s for s in (secrets or ()) if isinstance(s, str) and s},
                              key=len, reverse=True)

    def _plain(self, data):
        line = data.decode('utf-8', errors='replace')
        line = re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)', '', line)
        line = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', line)
        # Strip control bytes, including CR, but keep TAB for indented output.
        line = re.sub(r'[\x00-\x08\x0b-\x1f\x7f]', '', line)
        # C1 controls and Unicode format characters (bidi overrides and similar)
        # must not reach the rendered log; they can visually spoof output.
        cleaned = ''.join(ch for ch in line if ch == '\t' or unicodedata.category(ch) not in ('Cc', 'Cf'))
        for secret in self.secrets:
            cleaned = cleaned.replace(secret, '[REDACTED]')
        return cleaned

    def feed(self, block, final=False):
        out = []
        chunks = block.split(b'\n')
        for index, chunk in enumerate(chunks):
            complete = index < len(chunks) - 1
            if not self.discarding:
                self.pending.extend(chunk)
                if len(self.pending) > self.max_line:
                    self.pending.clear()
                    self.discarding = True
            if complete:
                if self.discarding:
                    out.append('[超长日志行已丢弃]\n')
                else:
                    out.append(self._plain(bytes(self.pending)) + '\n')
                self.pending.clear()
                self.discarding = False
        if final:
            if self.discarding:
                out.append('[超长日志行已丢弃]\n')
            elif self.pending:
                out.append(self._plain(bytes(self.pending)))
            self.pending.clear()
            self.discarding = False
        return ''.join(out).encode('utf-8')


STAGE_COMMANDS = {
    'all': ('all',),
    'prepare': ('access', 'prepare', 'deps', 'services-init', 'services-verify'),
    'harbor': ('harbor-install', 'harbor-projects', 'images-import', 'images-verify'),
    'k8s': ('k8s-install', 'node-images-verify', 'cluster-verify', 'ledger'),
}
VALID_STAGES = frozenset(STAGE_COMMANDS)


class CLIRunner:
    """Runs the shared CLI workflow for the requested stage group."""
    def __init__(self, project):
        self.project = Path(project)

    def __call__(self, job, environment, emit):
        stage = job.get('stage') or 'all'
        if stage not in STAGE_COMMANDS:
            raise ValueError('invalid stage')
        environment = dict(environment)
        environment['RISE_LOG_LEVEL'] = 'debug' if job.get('debug') else 'info'
        environment['DELIVERY_GRANULAR_STEP'] = 'true'
        for step in STAGE_COMMANDS[stage]:
            emit(('[web] stage %s / %s\n' % (stage, step)).encode('utf-8'))
            argv = ['/bin/bash', '--noprofile', '--norc', str(self.project / 'deploy.sh'),
                    'cli', '--step', step, '--env', job['config_path'], '--non-interactive']
            if job.get('debug'):
                argv.append('--debug')
            with subprocess.Popen(argv, cwd=str(Path(job['config_path']).parent), env=environment,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, start_new_session=True) as child:
                while True:
                    block = os.read(child.stdout.fileno(), 8192)
                    if not block:
                        break
                    emit(block)
                code = child.wait()
                if code != 0:
                    return code
            stop_file = environment.get('DELIVERY_STOP_FILE')
            if stop_file and Path(stop_file).exists():
                return 130
        return 0


class ExecutionService:
    def __init__(self, project_root, data_dir, work_root, allowed_uid, preview_cli=None,
                 runner=None, trusted_uid=0, plan_ttl=300, clock=None):
        self.trusted_uid = trusted_uid
        if type(allowed_uid) is not int or allowed_uid < 0:
            fail(400, 'invalid_uid', '必须指定允许连接的本机用户 UID。')
        self.allowed_uid = allowed_uid
        self.project = protected_path(project_root, trusted_uid, directory=True)
        self.digest = project_digest(self.project, trusted_uid)
        paths = [self.project, Path(os.path.abspath(str(data_dir))), Path(os.path.abspath(str(work_root)))]
        for index, left in enumerate(paths):
            for right in paths[index + 1:]:
                if left == right or left in right.parents or right in left.parents:
                    fail(400, 'invalid_roots', '发布目录、执行数据目录、工作目录必须独立，不能相同或互相包含。')
        self.data = managed_root(paths[1], 'data', trusted_uid)
        self.work = managed_root(paths[2], 'work', trusted_uid)
        self.lock = threading.RLock()
        self.lock_fd = os.open(str(self.data / 'executor.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.lock_fd)
            fail(409, 'executor_busy', '此任务目录已有执行器运行。')
        self.jobs_dir = protected_directory(self.data / 'jobs', trusted_uid)
        self.claims_dir = protected_directory(self.data / 'claims', trusted_uid)
        self.cluster_dir = protected_directory(self.data / 'cluster', trusted_uid)
        self.preview_cli = preview_cli
        self.runner = runner or CLIRunner(self.project)
        self.plan_ttl, self.clock = plan_ttl, clock or time.time
        self.plans, self.jobs, self.threads = {}, {}, {}
        self.closed = False
        self.recovery_required = False
        try:
            user = pwd.getpwuid(os.getuid()).pw_name
        except KeyError:
            user = str(os.getuid())
        self.identity = {'host': socket.gethostname(), 'user': user, 'uid': os.getuid()}
        try:
            self._recover()
        except BaseException:
            fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            os.close(self.lock_fd)
            raise

    def _recover(self):
        for path in self.jobs_dir.iterdir():
            if not UUID.fullmatch(path.name):
                fail(500, 'invalid_records', '任务目录含未知记录，请管理员核查。')
            protected_path(path, self.trusted_uid, directory=True)
            record = path / 'job.json'
            try:
                protected_path(record, self.trusted_uid)
                if record.stat().st_size > MAX_REQUEST:
                    raise ValueError('large record')
                job = strict_json(record.read_text(encoding='utf-8'))
                if job['id'] != path.name or job['state'] not in ACTIVE | {'succeeded', 'failed', 'stopped', 'interrupted'}:
                    raise ValueError('invalid job')
                if job['state'] in ACTIVE:
                    # The child runs in its own session and may still be alive
                    # after an executor crash. Ask it to stop at the next stage
                    # boundary before recording the unknown interrupt state.
                    try:
                        private_write(path / 'stop-requested', b'recovery: stop at next stage boundary\n')
                    except OSError:
                        pass  # The durable interrupted record still blocks new jobs.
                    job.update(state='interrupted', updated_at=stamp(), message='执行器曾中断，实际节点状态未知；请按原配置和回执人工核查。')
                    private_write(record, encoded(job))
                if job['state'] == 'interrupted':
                    self.recovery_required = True
                self.jobs[path.name] = job
            except (OSError, ValueError, KeyError, TypeError):
                fail(500, 'invalid_records', '任务记录无法可靠恢复，请管理员核查；不会自动执行。')
        # A crash before the first job record still leaves an irrevocable claim.
        for path in self.claims_dir.iterdir():
            protected_path(path, self.trusted_uid)
            try:
                claim = strict_json(path.read_text(encoding='utf-8'))
                if claim['id'] not in self.jobs:
                    self.recovery_required = True
            except (ValueError, KeyError, OSError):
                fail(500, 'invalid_records', '集群占用记录损坏，请管理员核查。')

    def capabilities(self):
        return {'enabled': True, 'executor': copy.deepcopy(self.identity), 'operation': 'all',
                'fresh_install_only': True, 'stop_mode': 'stage-boundary',
                'confirmation': 'acknowledgement', 'log_levels': ['info', 'debug'],
                'managed_state_root': str(self.cluster_dir), 'managed_work_root': str(self.work),
                'recovery_required': self.recovery_required}

    def _source_check(self):
        if project_digest(self.project, self.trusted_uid) != self.digest:
            fail(409, 'source_changed', '执行源码或工具已变化，请关闭执行器并重新审核发布副本。')

    def _effective(self, config):
        try:
            config = normalize_config(config)
        except ModelError as error:
            fail(400, 'invalid_config', str(error))
        settings = config['settings']
        cluster = settings['CLUSTER_NAME']
        if not CLUSTER.fullmatch(cluster):
            fail(400, 'invalid_cluster', '集群名称必须为小写字母开头的字母、数字或连字符，最多 63 位。')
        if not config['nodes'] or any(n['data_mode'] not in ('native', 'existing') for n in config['nodes']):
            fail(400, 'unsupported_storage', 'Web 非交互部署仅接受 native 或 existing 数据策略。')
        if settings['DEPS_MODE'] == 'online':
            fail(400, 'offline_required', 'Web 部署需要离线制品，不能选择 online。')
        artifact = self.project / 'artifact' / 'kubekey-artifact.tgz'
        resolved_sha = resolve_artifact_sha(self.project, settings['ARTIFACT_FILE'], settings['ARTIFACT_SHA256'])
        if resolved_sha:
            settings['ARTIFACT_SHA256'] = resolved_sha
        if settings['ARTIFACT_FILE'] != str(artifact) or not settings['ARTIFACT_SHA256']:
            fail(400, 'artifact_required', '必须选择执行器发布目录的 artifact/kubekey-artifact.tgz 并填写 SHA256。')
        protected_path(artifact, self.trusted_uid)
        settings['STATE_DIR'] = str(self.cluster_dir / cluster / 'state')
        settings['WORK_DIR'] = str(self.work / cluster)
        settings['VALIDATION_SCOPE'] = 'cluster'
        for index, node in enumerate(config['nodes'], 1):
            node['password_env'] = 'RISE_WEB_NODE_%s_PASSWORD' % index if node['connection'] == 'ssh' else ''
        self._inputs(config)
        # Derived paths must satisfy the same portable CLI grammar.
        return normalize_config(config)

    def _inputs(self, config):
        settings = config['settings']
        for key in ('HARBOR_CA', 'HARBOR_CERT', 'HARBOR_KEY'):
            if settings[key]:
                protected_path(settings[key], self.trusted_uid)
        if any(n['connection'] == 'ssh' for n in config['nodes']) and settings['SSH_AUTH_MODE'] != 'password':
            key = settings['SSH_KEY']
            if not key:
                fail(400, 'ssh_key_required', 'SSH 密钥或免密准备模式需要管理员控制的密钥路径。')
            protected_path(key, self.trusted_uid, absent=settings['SSH_AUTH_MODE'] == 'bootstrap')
            if Path(key).exists() and Path(key).stat().st_mode & 0o077:
                fail(400, 'untrusted_key', 'SSH 私钥必须仅允许执行器用户读取。')
            public = Path(key + '.pub')
            if public.exists() or public.is_symlink():
                protected_path(public, self.trusted_uid)
            if not Path(key).exists() and public.exists():
                fail(400, 'key_conflict', '私钥缺失但公钥文件已存在；请先通过 CLI 核查冲突。')

    def _credentials(self, config, stage='all'):
        required = []
        if stage != 'prepare' and config['settings']['COMPONENTS'] != 'k8s' and config['settings']['REGISTRY_MODE'] != 'external-harbor':
            required.append({'key': 'harbor', 'label': 'Harbor admin password', 'required': True})
        if config['settings']['SSH_AUTH_MODE'] == 'password':
            for node in config['nodes']:
                if node['connection'] == 'ssh':
                    required.append({'key': 'node:' + node['name'], 'label': node['name'] + ' SSH password',
                                     'required': True})
        return required

    @staticmethod
    def _changes(effective):
        """Settings that differ from the shipped defaults, for the confirmation UI."""
        default = default_config()
        changes = []
        # Executor-owned paths are already spelled out in the action list; do not
        # present them as operator changes.
        skip = {'STATE_DIR', 'WORK_DIR'}
        for key, value in effective['settings'].items():
            if key in skip:
                continue
            base = default['settings'].get(key)
            if value != base:
                changes.append({'key': key, 'from': base, 'to': value})
        if len(effective['nodes']) != len(default['nodes']):
            changes.append({'key': 'NODES', 'from': len(default['nodes']), 'to': len(effective['nodes'])})
        return changes

    @staticmethod
    def _actions(effective, result):
        """Concrete description of what the job will do, for the checkbox confirmation."""
        settings = effective['settings']
        steps = [step for step in (result.get('steps') or []) if isinstance(step, str)]
        actions = [
            '以 root 在控制端运行 deploy.sh all --non-interactive；一次只执行一个任务，不排队。',
            '按顺序执行阶段：%s。' % ' → '.join(steps),
            '离线制品：%s（SHA256 %s）。' % (settings['ARTIFACT_FILE'], settings['ARTIFACT_SHA256']),
            '实际 STATE_DIR：%s；实际 WORK_DIR：%s（由执行器管理，不改写草稿）。' % (settings['STATE_DIR'], settings['WORK_DIR']),
        ]
        if settings['COMPONENTS'] != 'k8s':
            actions.append('KubeKey 安装 Harbor（%s），并在 WORK_DIR/pki 生成镜像仓库 CA 与服务证书；节点信任该 CA。' % settings['REGISTRY_MODE'])
        if settings['COMPONENTS'] != 'harbor':
            modes = sorted({node.get('data_mode', '') for node in effective['nodes']})
            actions.append('KubeKey 安装 Kubernetes %s，CNI 为 Calico；数据策略 %s，不分区、不格式化。' % (settings['KUBE_VERSION'], '/'.join(modes)))
        actions.append('停止请求只在阶段边界生效；已完成的节点操作不回滚，也不自动清理。')
        return actions

    def preview(self, config, stage='all'):
        if not isinstance(stage, str) or stage not in VALID_STAGES:
            fail(400, 'invalid_stage', 'stage 必须为 all/prepare/harbor/k8s。')
        self._source_check()
        effective = self._effective(config)
        if stage == 'harbor' and effective['settings']['COMPONENTS'] == 'k8s':
            fail(400, 'invalid_stage', 'Harbor 未启用，不能执行 Harbor 阶段。')
        if stage == 'harbor' and effective['settings']['REGISTRY_MODE'] == 'external-harbor':
            fail(400, 'invalid_stage', '外部 Harbor 只读复用，不能执行受管 Harbor 安装阶段。')
        if stage == 'k8s' and effective['settings']['COMPONENTS'] == 'harbor':
            fail(400, 'invalid_stage', '仅 Harbour 范围不能执行 K8s 阶段。')
        if self.preview_cli is None:
            # Late import avoids a server/client/executor import cycle.
            from server import ReadOnlyCLI
            self.preview_cli = ReadOnlyCLI(self.project)
        try:
            result = self.preview_cli.run('plan', effective)
        except Exception:
            fail(502, 'plan_failed', '共享 CLI 只读计划生成失败，请检查执行器依赖和配置。')
        if not isinstance(result, dict) or result.get('valid') is not True:
            fail(400, 'invalid_config', '共享 CLI 校验未通过；请先修正表单并运行只读配置校验。')
        identifier = str(uuid.uuid4())
        digest = hashlib.sha256(encoded(effective)).hexdigest()
        expires = self.clock() + self.plan_ttl
        entry = {'plan_id': identifier, 'config_sha256': digest,
                 'expires_at': datetime.datetime.fromtimestamp(expires, datetime.timezone.utc).isoformat(timespec='seconds'),
                 'acknowledgement': {'version': 1, 'required': True,
                                     'label': '我已核对上述执行内容、配置变更和目标节点，同意开始安装'},
                 'actions': self._actions(effective, result),
                 'changes': self._changes(effective),
                 'effective_config': effective, 'plan': result, 'executor': copy.deepcopy(self.identity),
                 'stage': stage,
                 'required_credentials': self._credentials(effective, stage),
                 'warnings': []}
        entry['warnings'] = ['仅新环境首装；已有集群维护必须使用 CLI。',
                             'STATE_DIR 和 WORK_DIR 使用执行器管理路径；草稿保持原值。',
                             '停止请求仅在阶段边界生效；关闭浏览器不会停止任务，也不会回滚。',
                             '静态计划不代表节点、磁盘、网络或制品已通过实机检查。']
        if effective['settings']['REGISTRY_MODE'] == 'ha-harbor':
            entry['warnings'].insert(0, 'HA Harbor 仅开放配置、校验和只读计划；执行需完成 VIP、token 共享与 VRID 实机验收后由 CLI 完成。')
        with self.lock:
            self.plans = {key: value for key, value in self.plans.items() if value['expiry'] > self.clock()}
            if len(self.plans) >= 64:
                fail(429, 'too_many_plans', '未过期计划过多，请稍后重试。')
            self.plans[identifier] = {'public': entry, 'expiry': expires}
        return copy.deepcopy(entry)

    def _environment(self, plan, credentials):
        if not isinstance(credentials, dict) or set(credentials) - {r['key'] for r in plan['required_credentials']}:
            fail(400, 'invalid_credentials', '凭据仅接受计划声明的 Harbor 和节点名称。')
        for spec in plan['required_credentials']:
            value = credentials.get(spec['key'], '')
            if (not isinstance(value, str) or len(value) > 4096
                    or any(unicodedata.category(c) in ('Cc', 'Cf', 'Cs') for c in value)
                    or len(value.encode('utf-8')) > 4096):
                fail(400, 'invalid_credentials', '密码必须为不含控制字符的单行文本，且不超过 4096 字节。')
            if spec['required'] and not value:
                fail(400, 'missing_credentials', '缺少计划要求的密码；密码不会保存到草稿。')
        if any(spec['key'] == 'harbor' for spec in plan['required_credentials']):
            if not re.fullmatch(r'[A-Za-z0-9.!_@%+=:-]{12,128}', credentials.get('harbor', '')):
                fail(400, 'invalid_credentials', 'Harbor 密码需 12–128 位，字符范围与 CLI 一致。')
        # Local-node steps (storage.sh, kernel/deps probes) need sbin tools such
        # as blkid/wipefs; /usr/bin:/bin alone breaks local connections. Keep a
        # fixed root PATH instead of inheriting the caller's environment.
        env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
               'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'}
        if 'harbor' in credentials:
            env['HARBOR_PASSWORD'] = credentials['harbor']
        for node in plan['effective_config']['nodes']:
            key = 'node:' + node['name']
            if node['connection'] == 'ssh' and credentials.get(key):
                env[node['password_env']] = credentials[key]
        return env

    def _save(self, job):
        private_write(self.jobs_dir / job['id'] / 'job.json', encoded(job))

    def submit(self, body):
        if set(body) not in ({'request_id', 'plan_id', 'config_sha256', 'acknowledged', 'credentials', 'debug'},
                             {'request_id', 'plan_id', 'config_sha256', 'acknowledged', 'credentials', 'debug', 'stage'}):
            fail(400, 'invalid_request', '提交字段不完整或包含不支持的字段。')
        stage = body.get('stage', 'all')
        if not isinstance(stage, str) or stage not in VALID_STAGES:
            fail(400, 'invalid_stage', 'stage 必须为 all/prepare/harbor/k8s。')
        identifier = body['request_id']
        if not isinstance(identifier, str) or not UUID.fullmatch(identifier):
            fail(400, 'invalid_id', 'request_id 必须为 UUID v4。')
        if body['acknowledged'] is not True:
            fail(400, 'acknowledgement_required', '必须勾选确认执行内容后才能开始安装。')
        if type(body['debug']) is not bool:
            fail(400, 'invalid_request', 'debug 必须是布尔值。')
        # Credentials intentionally do not form an idempotency fingerprint:
        # retries never replace, persist or reuse newly submitted secrets.
        binding = {'request_id': identifier, 'plan_id': body['plan_id'],
                   'config_sha256': body['config_sha256'], 'acknowledged': True,
                   'debug': body['debug'], 'stage': stage}
        if not isinstance(binding['plan_id'], str) or not isinstance(binding['config_sha256'], str):
            fail(400, 'invalid_request', '计划 ID 与配置摘要必须为文本。')
        with self.lock:
            if identifier in self.jobs:
                stored = self.jobs_dir / identifier / 'binding.json'
                if strict_json(stored.read_text(encoding='utf-8')) != binding:
                    fail(409, 'idempotency_conflict', '该 request_id 已绑定其他提交，不能重复执行。')
                return self._snapshot(self.jobs[identifier])
            if self.closed:
                fail(503, 'executor_closing', '执行器正在关闭。')
            if self.recovery_required:
                fail(409, 'recovery_required', '执行器曾中断，需管理员核查已有任务后处理，禁止自动重新部署。')
            if any(job['state'] in ACTIVE for job in self.jobs.values()):
                fail(409, 'job_busy', '已有部署任务执行中；不自动排队。')
            slot = self.plans.get(body['plan_id'])
            if not slot or slot['expiry'] <= self.clock():
                fail(409, 'plan_expired', '计划已失效，请重新生成并确认。')
            plan = slot['public']
            if body['config_sha256'] != plan['config_sha256']:
                fail(409, 'confirmation_mismatch', '配置摘要与计划不一致；请重新准备部署。')
            if stage != plan.get('stage', 'all'):
                fail(409, 'stage_mismatch', '阶段与计划不一致；请重新准备。')
            if plan['effective_config']['settings']['REGISTRY_MODE'] == 'ha-harbor':
                fail(400, 'unsupported_ha', 'HA Harbor 仅支持配置与只读计划；请完成实机验收后由 CLI 执行。')
            self._source_check()
            self._inputs(plan['effective_config'])
            env = self._environment(plan, body['credentials'])
            settings = plan['effective_config']['settings']
            cluster = settings['CLUSTER_NAME']
            claim = self.claims_dir / (cluster + '.json')
            is_continuation = False
            if claim.exists() or claim.is_symlink():
                if stage in ('prepare', 'harbor', 'k8s'):
                    try:
                        claim_data = strict_json(claim.read_text(encoding='utf-8'))
                        prev_id = claim_data.get('id')
                        prev_job = self.jobs.get(prev_id)
                        if (prev_job and prev_job.get('state') not in ACTIVE
                                and prev_job.get('state') != 'interrupted'
                                and not (prev_job.get('stage') in ('all', 'k8s') and prev_job.get('state') == 'succeeded')):
                            if prev_job.get('config_sha256') != plan['config_sha256']:
                                fail(409, 'config_changed_between_stages', '分阶段提交期间集群配置已变化；请恢复原配置或由管理员通过 CLI 核查。')
                            is_continuation = True
                    except ExecutionError:
                        raise
                    except Exception:
                        pass
                if not is_continuation:
                    fail(409, 'cluster_claimed', '此集群已有部署任务记录；请使用原配置和 CLI 核查维护，禁止重复首装。')
            state = Path(settings['STATE_DIR'])
            if not is_continuation and (state.parent.exists() or Path(settings['WORK_DIR']).exists()):
                fail(409, 'existing_environment', '管理状态或工作目录已存在；Web 仅支持新环境首装。')
            # Claim is durable before any child or workflow state can be created.
            private_write(claim, encoded({'id': identifier, 'cluster_name': cluster, 'created_at': stamp()}))
            try:
                directory = protected_directory(self.jobs_dir / identifier, self.trusted_uid)
                protected_directory(state.parent, self.trusted_uid)
                protected_directory(settings['WORK_DIR'], self.trusted_uid)
                config_path = directory / 'config.env'
                private_write(config_path, export_env(plan['effective_config']).encode('utf-8'))
                private_write(directory / 'binding.json', encoded(binding))
                private_write(directory / 'output.log', b'')
                now = stamp()
                job = {'id': identifier, 'state': 'queued', 'cluster_name': cluster, 'created_at': now, 'updated_at': now,
                       'exit_code': None, 'stop_requested': False, 'message': '已确认，准备执行。',
                       'config_sha256': plan['config_sha256'], 'config_path': str(config_path),
                       'state_dir': str(state), 'work_dir': settings['WORK_DIR'], 'executor': copy.deepcopy(self.identity),
                       'operation': stage, 'stage': stage, 'debug': body['debug'],
                       'log_level': 'debug' if body['debug'] else 'info'}
                self.jobs[identifier] = job
                self._save(job)
                del self.plans[body['plan_id']]
                env['DELIVERY_STOP_FILE'] = str(directory / 'stop-requested')
                thread = threading.Thread(target=self._run, args=(identifier, env), name='deploy-' + identifier, daemon=False)
                self.threads[identifier] = thread
                thread.start()
            except Exception:
                self.recovery_required = True
                fail(500, 'submission_unconfirmed', '任务提交结果未确认；占用记录已保留，请勿重复首装，交由管理员核查。')
            return self._snapshot(job)

    def _run(self, identifier, env):
        # Mask submitted memory credentials while retaining 1 MiB head + 3 MiB tail.
        secret_values = [
            val for key, val in env.items()
            if key == 'HARBOR_PASSWORD' or (key.startswith('RISE_WEB_NODE_') and key.endswith('_PASSWORD'))
        ]
        decoder = JobLog(secrets=secret_values)
        path = self.jobs_dir / identifier / 'output.log'
        retained = 0
        compacted = False
        head_buf = bytearray()
        tail_chunks = deque()
        tail_size = 0
        omitted_bytes = 0
        unflushed_overflow = 0
        stream_failed = False

        def flush_compacted():
            marker = ('[日志已超过 4 MiB 上限；中间已省略 %d 字节，以下保留最新尾部输出]\n' % omitted_bytes).encode('utf-8')
            payload = bytes(head_buf) + marker + b''.join(tail_chunks)
            private_write(path, payload)

        def emit(block, final=False):
            nonlocal retained, compacted, tail_size, omitted_bytes, unflushed_overflow, stream_failed
            if stream_failed:
                return  # Keep draining the child pipe without retaining output.
            safe = decoder.feed(block, final=final)
            if not safe:
                if final and compacted and unflushed_overflow > 0:
                    try:
                        with self.lock:
                            flush_compacted()
                            unflushed_overflow = 0
                    except OSError:
                        pass
                return
            try:
                with self.lock:
                    if not compacted and retained + len(safe) <= MAX_LOG:
                        fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
                        with os.fdopen(fd, 'ab') as stream:
                            stream.write(safe)
                        retained += len(safe)
                        return
                    if not compacted:
                        existing = path.read_bytes() if path.exists() else b''
                        combined = existing + safe
                        split_at = min(HEAD_LOG, len(combined))
                        nl = combined.rfind(b'\n', max(0, split_at - 1024), split_at)
                        if nl > 0:
                            split_at = nl + 1
                        head_buf.extend(combined[:split_at])
                        remainder = combined[split_at:]
                        compacted = True
                        self.jobs[identifier]['log_compacted'] = True
                    else:
                        remainder = safe
                    for line in remainder.splitlines(keepends=True):
                        if len(line) > TAIL_LOG:
                            omitted_bytes += len(line) - TAIL_LOG
                            line = line[-TAIL_LOG:]
                        tail_chunks.append(line)
                        tail_size += len(line)
                        while tail_size > TAIL_LOG and tail_chunks:
                            dropped = tail_chunks.popleft()
                            tail_size -= len(dropped)
                            omitted_bytes += len(dropped)
                    unflushed_overflow += len(remainder)
                    if final or unflushed_overflow >= 65536:
                        flush_compacted()
                        unflushed_overflow = 0
            except OSError:
                stream_failed = True
                # A full disk may also prevent this marker, but never abandon
                # the stdout pipe and deadlock a still-running installation.
                marker_written = False
                try:
                    private_write(self.jobs_dir / identifier / 'stop-requested', b'log failure: stop at stage boundary\n')
                    marker_written = True
                except OSError:
                    pass
                with self.lock:
                    self.recovery_required = True
                    job = self.jobs[identifier]
                    job.update(stop_requested=True, state='stop_requested', updated_at=stamp(),
                               message=('日志保存失败，已请求阶段边界停止；现场需管理员核查。' if marker_written else
                                        '日志保存失败，停止标记写入未确认；任务可能继续，需管理员立即核查。'))
                    try:
                        self._save(job)
                    except OSError:
                        pass
        try:
            with self.lock:
                job = self.jobs[identifier]
                self._source_check()
                if job['stop_requested']:
                    job.update(state='stopped', exit_code=130, updated_at=stamp(), message='任务在开始前收到停止请求，未启动 CLI。')
                    self._save(job)
                    return
                job.update(state='running', updated_at=stamp(), message='CLI 正在执行；进度以阶段回执为准。')
                self._save(job)
                runner_job = copy.deepcopy(job)
            rc = self.runner(runner_job, env, emit)
            emit(b'', final=True)
            if stream_failed or type(rc) is not int:
                raise RuntimeError('execution observability lost')
            with self.lock:
                job = self.jobs[identifier]
                state = 'succeeded' if rc == 0 else ('stopped' if rc == 130 and job['stop_requested'] else 'failed')
                job.update(state=state, exit_code=rc, updated_at=stamp(), message={
                    'succeeded': 'CLI 全流程已完成；请核对最终验收回执。',
                    'stopped': 'CLI 已在阶段边界停止，已完成步骤和数据保留，不代表回滚。',
                    'failed': 'CLI 返回失败，保留原配置和回执；请先核查再通过 CLI 处理。'}[state])
                self._save(job)
        except BaseException:
            # Do not expose exception text: fake/real subprocess errors can
            # include arguments or credentials. Persist a conservative state.
            with self.lock:
                job = self.jobs[identifier]
                job.update(state='interrupted', updated_at=stamp(), message='执行结果未知，保留现场；请管理员核查进程、节点及回执。')
                self.recovery_required = True
                try:
                    self._save(job)
                except OSError:
                    pass  # Previous durable running record forces recovery.
        finally:
            env.clear()

    def _snapshot(self, job):
        result = copy.deepcopy(job)
        workflow = Path(job['state_dir'] + '.workflow')
        # Read only generated, bounded stage records. Never trust a supplied path
        # in a receipt, and never follow a record's run/evidence path here.
        newest = None
        if workflow.exists():
            protected_path(workflow, self.trusted_uid, directory=True)
            for record in workflow.glob('*.json'):
                if record.stat().st_size > 64 * 1024:
                    continue
                try:
                    protected_path(record, self.trusted_uid)
                except ExecutionError:
                    # One foreign/symlinked record must not make every job view
                    # fail; show the last usable stage instead.
                    continue
                try:
                    value = strict_json(record.read_text(encoding='utf-8'))
                    if isinstance(value.get('stage'), str) and re.fullmatch(r'[a-z-]{1,40}', value['stage']):
                        item = (record.stat().st_mtime_ns, value['stage'])
                        newest = max(newest, item) if newest else item
                except (ValueError, OSError, AttributeError):
                    continue
        result['stage'] = result.get('stage') or 'all'
        if newest:
            result['workflow_stage'] = newest[1]
        return result

    def _job(self, identifier):
        if not isinstance(identifier, str) or not UUID.fullmatch(identifier) or identifier not in self.jobs:
            fail(404, 'not_found', '没有找到该任务。')
        return self.jobs[identifier]

    def logs(self, identifier, offset):
        if type(offset) is not int or offset < 0 or offset > MAX_LOG + 4096:
            fail(400, 'invalid_offset', '日志 offset 必须为范围内的非负整数。')
        with self.lock:
            job = self._job(identifier)
            path = self.jobs_dir / identifier / 'output.log'
            protected_path(path, self.trusted_uid)
            with path.open('rb') as stream:
                size = os.fstat(stream.fileno()).st_size
                compacted = bool(job.get('log_compacted'))
                if offset > size:
                    if compacted:
                        return {'text': '', 'next_offset': size, 'truncated': True}
                    fail(400, 'invalid_offset', '日志 offset 超出已保存内容。')
                stream.seek(offset)
                data = stream.read(MAX_LOG_READ)
                stream.seek(max(0, size - len(LOG_LIMIT_MARKER)))
                capped = compacted or (stream.read() == LOG_LIMIT_MARKER)
            # Byte offsets are stable. Decode replacement is safe for an offset
            # inside UTF-8, and callers normally use the returned next_offset.
            return {'text': data.decode('utf-8', errors='replace'), 'next_offset': offset + len(data),
                    'truncated': size > offset + len(data) or capped}

    def stop(self, identifier):
        with self.lock:
            job = self._job(identifier)
            if job['state'] in ACTIVE:
                try:
                    private_write(self.jobs_dir / identifier / 'stop-requested', b'stop at next stage boundary\n')
                except OSError:
                    job.update(message='停止标记写入失败，任务可能继续；请管理员核查，不代表已停止。', updated_at=stamp())
                    self.recovery_required = True
                    try:
                        self._save(job)
                    except OSError:
                        pass
                    fail(503, 'stop_unconfirmed', '停止请求未确认；任务可能继续，请管理员核查。')
                job.update(stop_requested=True, state='stop_requested', updated_at=stamp(),
                           message='已请求在阶段边界停止；当前阶段可能继续运行，不会强杀或回滚。')
                self._save(job)
            return self._snapshot(job)

    def ledger(self):
        """Return the newest generated ledger as bounded, read-only bytes."""
        candidates = []
        candidates.extend(self.project.glob('runs/*/k8s_harbor_deployment_inventory.xlsx'))
        candidates.extend(self.project.glob('runs/*/environment-ledger.xlsx'))
        candidates.extend(self.project.glob('runs/*/ledger/k8s_harbor_deployment_inventory.xlsx'))
        candidates.extend(self.project.glob('runs/*/ledger/environment-ledger.xlsx'))
        candidates.extend(self.cluster_dir.rglob('k8s_harbor_deployment_inventory.xlsx'))
        candidates.extend(self.cluster_dir.rglob('environment-ledger.xlsx'))
        candidates.extend(self.work.rglob('k8s_harbor_deployment_inventory.xlsx'))
        candidates.extend(self.work.rglob('environment-ledger.xlsx'))
        usable = []
        for path in candidates:
            try:
                protected_path(path, self.trusted_uid)
                info = path.stat()
                if info.st_size <= 4 * 1024 * 1024:
                    usable.append((info.st_mtime_ns, path))
            except (OSError, ExecutionError):
                continue
        if not usable:
            fail(404, 'ledger_missing', '尚未生成可下载的台账；请先完成 ledger 阶段。')
        path = max(usable, key=lambda item: item[0])[1]
        payload = path.read_bytes()
        return {'filename': path.name, 'sha256': hashlib.sha256(payload).hexdigest(),
                'bytes': len(payload), 'data': base64.b64encode(payload).decode('ascii')}

    def artifact_sha256(self, path):
        """Stream a package artifact digest; only under this trusted project."""
        if not isinstance(path, str) or not path or len(path) > 4096:
            fail(400, 'invalid_path', '归档路径必须为文本且不超过 4096 字符。')
        if '\x00' in path or '\n' in path or '\r' in path or '..' in Path(path).parts:
            fail(400, 'invalid_path', '归档路径不能包含控制字符或上级跳转。')
        candidate = Path(path)
        if not candidate.is_absolute():
            fail(400, 'invalid_path', '归档路径必须为绝对路径。')
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(self.project.resolve())
        except (OSError, ValueError):
            fail(400, 'artifact_outside_project', '为防敏感文件读取，只允许计算执行器发布目录内的普通归档文件。')
        try:
            protected_path(resolved, self.trusted_uid)
            if resolved.is_symlink():
                fail(400, 'artifact_symlink', '归档路径不能是符号链接。')
            fd = os.open(str(resolved), os.O_RDONLY | os.O_NOFOLLOW)
        except ExecutionError:
            raise
        except OSError:
            fail(400, 'artifact_unavailable', '归档文件不存在或不可读。')
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                fail(400, 'artifact_not_regular', '归档必须是普通文件。')
            if info.st_size > 8 * 1024 * 1024 * 1024:
                fail(413, 'artifact_too_large', '归档超过 8 GiB 计算上限。')
            digest = hashlib.sha256()
            deadline = time.monotonic() + 90
            read = 0
            while True:
                block = os.read(fd, 4 * 1024 * 1024)
                if not block:
                    break
                digest.update(block)
                read += len(block)
                if time.monotonic() > deadline:
                    fail(504, 'artifact_hash_timeout', '归档摘要计算超过 90 秒，已停止；请缩短路径或使用 CLI 计算。')
            if read != info.st_size:
                fail(409, 'artifact_changed', '归档在计算期间发生变化，请重新核对文件后重试。')
            return {'sha256': digest.hexdigest(), 'bytes': info.st_size, 'path': str(resolved)}
        finally:
            os.close(fd)

    def request(self, op, body=None):
        body = {} if body is None else body
        if op == 'capabilities':
            shape(body, ()); return self.capabilities()
        if op == 'ledger':
            shape(body, ()); return self.ledger()
        if op == 'artifact_sha256':
            shape(body, ('path',)); return self.artifact_sha256(body['path'])
        if op == 'preview':
            if set(body) not in ({'config'}, {'config', 'stage'}):
                fail(400, 'invalid_request', '预览字段不完整或包含不支持的字段。')
            return self.preview(body['config'], body.get('stage', 'all'))
        if op == 'submit':
            return self.submit(body)
        if op == 'list':
            shape(body, ())
            with self.lock:
                return {'jobs': [self._snapshot(job) for job in sorted(self.jobs.values(), key=lambda x: x['created_at'], reverse=True)]}
        if op == 'get':
            shape(body, ('id',))
            with self.lock:
                return self._snapshot(self._job(body['id']))
        if op == 'logs':
            shape(body, ('id', 'offset')); return self.logs(body['id'], body['offset'])
        if op == 'stop':
            shape(body, ('id',)); return self.stop(body['id'])
        fail(404, 'not_found', '执行器不支持该操作。')

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
            for identifier, job in self.jobs.items():
                if job['state'] in ACTIVE:
                    try:
                        self.stop(identifier)
                    except ExecutionError:
                        pass  # Keep waiting; never force-kill on disk failure.
        for thread in self.threads.values():
            thread.join()
        fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
        os.close(self.lock_fd)
