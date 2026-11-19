#!/usr/bin/env python3
"""Loopback configuration workbench with an explicitly connected executor."""
import argparse
import base64
import datetime
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unicodedata
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from artifact_digest import resolve as resolve_artifact_sha
from config_model import ModelError, default_config, export_env, import_env, normalize_config, schema

MAX_BODY = 256 * 1024
MAX_DRAFTS = 200
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
STATIC = {'/': ('index.html', 'text/html; charset=utf-8'),
          '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
          '/workbench-logic.js': ('workbench-logic.js', 'text/javascript; charset=utf-8'),
          '/style.css': ('style.css', 'text/css; charset=utf-8')}


class APIError(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message
        super().__init__(message)


def strict_json(text):
    def pairs(items):
        out = {}
        for key, value in items:
            if key in out:
                raise ValueError('duplicate JSON key')
            out[key] = value
        return out
    def nonfinite(value):
        raise ValueError('non-finite JSON number')
    return json.loads(text, object_pairs_hook=pairs, parse_constant=nonfinite)


def shape(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise APIError(400, 'invalid_request', '请求字段不完整或包含不支持的字段。')


def normalize_credentials(value, config):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise APIError(400, 'invalid_credentials', 'credentials 必须是对象。')
    allowed = {'harbor'} | {'node:' + node['name'] for node in config['nodes'] if node.get('name')}
    if set(value) - allowed:
        raise APIError(400, 'invalid_credentials', '凭据键必须是 harbor 或当前节点名称。')
    result = {}
    for key, item in value.items():
        if not isinstance(item, str) or len(item) > 4096:
            raise APIError(400, 'invalid_credentials', '凭据必须是不超过 4096 字节的文本。')
        if any(ord(ch) < 32 or 0x7f <= ord(ch) <= 0x9f for ch in item):
            raise APIError(400, 'invalid_credentials', '凭据不能包含控制字符。')
        result[key] = item
    return result


def with_artifact_sha(project, config):
    config = normalize_config(config)
    settings = config['settings']
    digest = resolve_artifact_sha(project, settings.get('ARTIFACT_FILE', ''), settings.get('ARTIFACT_SHA256', ''))
    if digest:
        settings['ARTIFACT_SHA256'] = digest
    return config


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def artifact_suggestion(project):
    """Suggest only the fixed bundled archive; never read its content or scan paths."""
    candidate = project / 'artifact' / 'kubekey-artifact.tgz'
    config = default_config()
    config['settings']['ARTIFACT_FILE'] = str(candidate)
    try:
        normalize_config(config)
    except ModelError:
        return {'value': None, 'reason': '解包目录含中文、空格或不支持的路径字符。请将交付包解压到无此类字符的独立目录，再填写内层制品绝对路径。'}
    try:
        info = candidate.lstat()
        if not stat.S_ISREG(info.st_mode) or candidate.resolve(strict=True) != candidate:
            raise ValueError('not a regular bundled archive')
    except (OSError, ValueError):
        return {'value': None, 'reason': '未找到固定包内路径 artifact/kubekey-artifact.tgz 的普通文件；不会扫描其他目录，请核对交付完整性。'}
    return {'value': str(candidate), 'reason': '来自当前解包目录的固定内层制品路径；仅确认文件存在，未读取内容或验证摘要。填入后仍须按交付清单核验 SHA256。'}


def regular_private(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise APIError(409, 'unsafe_storage', '草稿文件所有者、类型或权限不符合要求。')
    return info


class DraftStore:
    """Own one private directory; refuse to adopt unrelated existing data."""
    def __init__(self, directory, project):
        self.lock = threading.RLock()
        self.lock_fd = None
        raw = Path(directory).absolute()
        if raw.is_symlink():
            raise ValueError('草稿目录不能是符号链接。')
        self.directory = raw.resolve()
        if self.directory == project or project in self.directory.parents or self.directory in project.parents:
            raise ValueError('草稿目录必须独立于项目目录及其父目录。')
        existed = self.directory.exists()
        if not existed:
            self.directory.mkdir(mode=0o700, parents=False)
        info = self.directory.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('草稿目录必须由当前用户所有且权限为 0700。')
        marker = self.directory / '.config-web-store.json'
        members = list(self.directory.iterdir())
        if members and not marker.exists():
            raise ValueError('现有目录非空且不是专用 Web 草稿目录，拒绝接管。')
        if marker.exists():
            regular_private(marker)
            if strict_json(marker.read_text()) != {'format': 'rise-config-web', 'version': 1}:
                raise ValueError('草稿目录标识不兼容。')
        lockfile = self.directory / '.config-web.lock'
        fd = os.open(lockfile, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            regular_private(lockfile)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(fd)
            raise ValueError('草稿目录不安全或已被另一个 Web 服务使用。')
        self.lock_fd = fd
        if not marker.exists():
            self._atomic(marker, {'format': 'rise-config-web', 'version': 1})

    def close(self):
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None

    def _atomic(self, target, value):
        fd, temp = tempfile.mkstemp(prefix='.draft-', dir=str(self.directory))
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                json.dump(value, stream, ensure_ascii=False, allow_nan=False, indent=2)
                stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
            os.replace(temp, target)
            directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

    def _path(self, identifier):
        if not isinstance(identifier, str) or not UUID.fullmatch(identifier):
            raise APIError(404, 'not_found', '草稿不存在。')
        return self.directory / (identifier + '.json')

    def _read(self, identifier):
        path = self._path(identifier)
        try:
            info = regular_private(path)
        except FileNotFoundError:
            raise APIError(404, 'not_found', '草稿不存在。')
        if info.st_size > MAX_BODY * 2:
            raise APIError(409, 'invalid_draft', '草稿内容超过限制。')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            with os.fdopen(fd, 'r', encoding='utf-8') as stream:
                item = strict_json(stream.read(MAX_BODY * 2 + 1))
            if set(item) not in ({'id', 'name', 'revision', 'created_at', 'updated_at', 'config'},
                                 {'id', 'name', 'revision', 'created_at', 'updated_at', 'config', 'credentials'}):
                raise ValueError('invalid draft fields')
            if item['id'] != identifier or type(item['revision']) is not int or item['revision'] < 1:
                raise ValueError('invalid draft')
            self._name(item['name'])
            for key in ('created_at', 'updated_at'):
                if not isinstance(item[key], str) or len(item[key]) > 64:
                    raise ValueError('invalid date')
            item['config'] = normalize_config(item['config'])
            item['credentials'] = normalize_credentials(item.get('credentials', {}), item['config'])
            return item
        except (ValueError, TypeError, UnicodeError, APIError):
            raise APIError(409, 'invalid_draft', '草稿内容无效，请保留原文件并人工核对。')

    @staticmethod
    def _name(name):
        if (not isinstance(name, str) or not name.strip() or len(name) > 80
                or any(unicodedata.category(c) in ('Cc', 'Cf', 'Cs') for c in name)):
            raise APIError(400, 'invalid_name', '草稿名称须为 1–80 个可显示字符。')
        return name.strip()

    def list(self):
        with self.lock:
            paths = list(self.directory.glob('*.json'))
            paths = [p for p in paths if p.name != '.config-web-store.json']
            if len(paths) > MAX_DRAFTS:
                raise APIError(409, 'draft_limit', '草稿数量超过限制，请人工归档。')
            items = [self._read(p.stem) for p in paths]
            return [{k: row[k] for k in ('id', 'name', 'revision', 'updated_at')}
                    for row in sorted(items, key=lambda row: row['updated_at'], reverse=True)]

    def get(self, identifier):
        with self.lock:
            return self._read(identifier)

    def save(self, name, config, identifier=None, revision=None, credentials=None):
        name = self._name(name)
        config = normalize_config(config)
        with self.lock:
            if identifier is None:
                if len(self.list()) >= MAX_DRAFTS:
                    raise APIError(409, 'draft_limit', '最多保存 200 个草稿，请人工归档。')
                identifier = str(uuid.uuid4())
                previous = None
            else:
                previous = self._read(identifier)
                if type(revision) is not int or revision != previous['revision']:
                    raise APIError(409, 'revision_conflict', '草稿已更新，请先重新打开核对；本次没有覆盖。')
            if credentials is None:
                credentials = previous['credentials'] if previous else {}
            credentials = normalize_credentials(credentials, config)
            item = {'id': identifier, 'name': name, 'revision': 1 if previous is None else revision + 1,
                    'created_at': timestamp() if previous is None else previous['created_at'],
                    'updated_at': timestamp(), 'config': config, 'credentials': credentials}
            self._atomic(self._path(identifier), item)
            return item


class ReadOnlyCLI:
    def __init__(self, project):
        self.project = project
        self.gate = threading.BoundedSemaphore(2)

    def run(self, operation, config):
        if operation not in ('config-check', 'plan'):
            raise APIError(404, 'not_found', '不支持该操作。')
        config = normalize_config(config)
        digest = resolve_artifact_sha(self.project, config['settings'].get('ARTIFACT_FILE', ''),
                                      config['settings'].get('ARTIFACT_SHA256', ''))
        if digest:
            config['settings']['ARTIFACT_SHA256'] = digest
        # SSH_KEY/HARBOR_KEY are never opened by the read-only Web validator.
        settings = config['settings']
        if not self.gate.acquire(blocking=False):
            raise APIError(429, 'busy', '已有配置校验正在运行，请稍后重试。')
        try:
            with tempfile.TemporaryDirectory(prefix='rise-web-config-', dir='/tmp') as directory:
                envfile = Path(directory) / 'validated.env'
                envfile.write_text(export_env(config), encoding='utf-8'); envfile.chmod(0o600)
                argv = ['/bin/bash', '--noprofile', '--norc', str(self.project / 'deploy.sh'), operation,
                        '--env', str(envfile), '--json']
                env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                       'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'}
                process = subprocess.Popen(argv, cwd=directory, env=env, stdin=subprocess.DEVNULL,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    stdout, stderr = process.communicate(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.communicate()
                    raise APIError(504, 'validation_timeout', '只读校验超时，已停止校验子进程。')
                if len(stdout) + len(stderr) > 512 * 1024:
                    raise APIError(502, 'invalid_cli_response', '校验输出超过限制。')
                diagnostic = stderr.decode('utf-8', errors='replace').replace(directory, '[temporary-config]')
                if process.returncode:
                    # CLI's generic recovery hint mentions node mutations. This
                    # adapter never runs those paths; display only parameter
                    # errors, not inapplicable deployment recovery suggestions.
                    errors = [line[len('[ERROR] '):] for line in diagnostic.splitlines()
                              if line.startswith('[ERROR] ')]
                    return {'valid': False, 'result': None,
                            'errors': errors or ['只读配置校验失败，请检查本机 Bash/jq 等工具依赖。']}
                try:
                    result = strict_json(stdout.decode('utf-8'))
                    if (not isinstance(result, dict) or result.get('schema_version') != 1 or result.get('kind') != operation
                            or result.get('valid') is not True or result.get('execution_authorized') is not False
                            or result.get('live_checks_performed') is not False):
                        raise ValueError('wrong contract')
                except (ValueError, UnicodeError):
                    raise APIError(502, 'invalid_cli_response', '只读接口返回了不兼容的结果。')
                return {'valid': True, 'result': result, 'errors': []}
        finally:
            self.gate.release()


class WebServer(ThreadingHTTPServer):
    # Finish bounded requests before releasing the cross-process draft lock.
    daemon_threads = False
    allow_reuse_address = True

    def server_close(self):
        super().server_close()
        if hasattr(self, 'drafts'):
            self.drafts.close()


class Handler(BaseHTTPRequestHandler):
    server_version = 'ConfigWorkbench/1'
    sys_version = ''
    protocol_version = 'HTTP/1.0'

    def setup(self):
        super().setup()
        # Artifact SHA256 can stream a multi-GiB file on the privileged
        # executor; keep the loopback request timeout bounded but large enough.
        self.connection.settimeout(120)

    def log_message(self, format, *args):
        # Never log tokens, imported configuration, request bodies or paths.
        return

    def _send(self, code, content, content_type='application/json; charset=utf-8', filename=None):
        if not isinstance(content, bytes):
            content = json.dumps(content, ensure_ascii=False, allow_nan=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(content)))
        self.send_header('Cache-Control', 'no-store')
        if filename:
            if not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', filename):
                raise APIError(500, 'invalid_ledger_name', '台账文件名不安全。')
            self.send_header('Content-Disposition', 'attachment; filename="' + filename + '"')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
        self.send_header('Connection', 'close')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(content)

    def _gate(self):
        expected = '127.0.0.1:' + str(self.server.server_port)
        hosts = self.headers.get_all('Host', [])
        origins = self.headers.get_all('Origin', [])
        if hosts != [expected]:
            raise APIError(403, 'host_rejected', '仅接受本机回环地址。')
        if len(origins) > 1 or origins and origins != ['http://' + expected]:
            raise APIError(403, 'origin_rejected', '请求来源不符合本机同源要求。')
        if self.headers.get('Sec-Fetch-Site', '') == 'cross-site':
            raise APIError(403, 'origin_rejected', '拒绝跨站请求。')
        if self.path.startswith('/api/'):
            tokens = self.headers.get_all('X-Web-Token', [])
            if len(tokens) != 1 or not tokens[0].isascii() or not hmac.compare_digest(tokens[0], self.server.web_token):
                raise APIError(401, 'authentication_required', '请通过当前服务启动时的本机链接进入。')
            if self.command in ('POST', 'PUT') and origins != ['http://' + expected]:
                raise APIError(403, 'origin_rejected', '写入请求必须携带本机同源 Origin。')

    def _body(self):
        if self.headers.get_all('Transfer-Encoding'):
            raise APIError(400, 'invalid_request', '不支持传输编码。')
        lengths = self.headers.get_all('Content-Length', [])
        if len(lengths) != 1 or not re.fullmatch(r'[0-9]+', lengths[0]):
            raise APIError(400, 'invalid_request', '需要明确的请求长度。')
        length = int(lengths[0])
        if length > MAX_BODY:
            raise APIError(413, 'request_too_large', '配置或导入文本超过 256 KiB 限制。')
        if self.headers.get('Content-Type', '').split(';', 1)[0].strip().lower() != 'application/json':
            raise APIError(415, 'unsupported_media_type', '仅接受 JSON 请求。')
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise APIError(400, 'invalid_json', 'JSON 请求不完整。')
        try:
            return strict_json(raw.decode('utf-8'))
        except (ValueError, UnicodeError, RecursionError):
            raise APIError(400, 'invalid_json', 'JSON 格式、字段重复或数值不符合要求。')

    def _dispatch(self):
        self._gate()
        route = self.path
        if self.command in ('GET', 'HEAD') and route in STATIC:
            name, kind = STATIC[route]
            self._send(200, (Path(__file__).parent / 'static' / name).read_bytes(), kind); return
        if self.command == 'GET' and route == '/api/schema':
            self._send(200, {'schema': schema(), 'default_config': default_config(),
                             'suggestions': {'artifact_file': artifact_suggestion(self.server.cli.project)}}); return
        if self.command == 'GET' and route == '/api/execution':
            result = {'enabled': False} if self.server.execution is None else self._execute('capabilities', {})
            self._send(200, result); return
        if route == '/api/execution/artifact-sha256':
            if self.command != 'POST':
                raise APIError(405, 'method_not_allowed', '归档摘要接口只支持 POST。')
            if self.server.execution is None:
                raise APIError(404, 'execution_disabled', '当前服务未连接本机执行器，不能读取归档文件。')
            body = self._body(); shape(body, ['path'])
            if not isinstance(body['path'], str):
                raise APIError(400, 'invalid_path', '归档路径必须为文本。')
            self._send(200, self._execute('artifact_sha256', {'path': body['path']})); return
        if route == '/api/execution/probe-nodes':
            if self.command != 'POST':
                raise APIError(405, 'method_not_allowed', '节点探测接口只支持 POST。')
            if self.server.execution is None:
                raise APIError(404, 'execution_disabled', '当前服务未连接本机执行器，不能探测远端节点。')
            body = self._body()
            if set(body) not in ({'config'}, {'config', 'credentials'}):
                raise APIError(400, 'invalid_request', '节点探测请求字段不完整或包含不支持的字段。')
            config = normalize_config(body['config'])
            creds = normalize_credentials(body.get('credentials'), config)
            self._send(200, self._execute('probe_nodes', {'config': config, 'credentials': creds})); return
        if route == '/api/execution/clusters':
            if self.command != 'GET':
                raise APIError(405, 'method_not_allowed', '集群状态接口只支持 GET。')
            if self.server.execution is None:
                raise APIError(404, 'execution_disabled', '当前服务未连接本机执行器，无法读取受管集群状态。')
            self._send(200, self._execute('clusters', {})); return
        if route == '/api/execution/expand-workers':
            if self.command != 'POST':
                raise APIError(405, 'method_not_allowed', 'Worker 扩容接口只支持 POST。')
            if self.server.execution is None:
                raise APIError(404, 'execution_disabled', '当前服务未连接本机执行器，无法提交扩容任务。')
            body = self._body()
            required = {'request_id', 'cluster_name', 'new_nodes', 'credentials', 'debug'}
            if not isinstance(body, dict) or not required <= set(body) or set(body) - required - {'state_dir'}:
                raise APIError(400, 'invalid_request', '扩容请求字段不完整或包含不支持的字段。')
            self._send(200, self._execute('expand_workers', body)); return
        if route == '/api/ledger':
            if self.command != 'GET':
                raise APIError(405, 'method_not_allowed', '台账只支持 GET。')
            if self.server.execution is None:
                raise APIError(404, 'execution_disabled', '当前服务未连接执行器，无法读取执行器管理的台账。')
            result = self._execute('ledger', {})
            try:
                payload = base64.b64decode(result['data'], validate=True)
            except (KeyError, TypeError, ValueError):
                raise APIError(502, 'invalid_ledger', '执行器返回的台账内容无效。') from None
            self._send(200, payload, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                       filename=result.get('filename', 'environment-ledger.xlsx'))
            return
        if self.server.execution is not None and (route == '/api/jobs' or route.startswith('/api/jobs/')):
            self._jobs(route); return
        if self.command == 'POST' and route in ('/api/import', '/api/export', '/api/validate', '/api/plan'):
            body = self._body()
            if route == '/api/import':
                shape(body, ['text'])
                self._send(200, {'config': import_env(body['text'])})
            elif route == '/api/export':
                # Passwords are optional and only included when explicitly asked
                # for; the form keeps them in memory and never in a draft.
                if set(body) not in ({'config'}, {'config', 'credentials'},
                                     {'config', 'credentials', 'include_credentials'}):
                    raise APIError(400, 'invalid_request', '导出请求字段不完整或包含不支持的字段。')
                include = body.get('include_credentials', False)
                if type(include) is not bool:
                    raise APIError(400, 'invalid_request', 'include_credentials 必须是布尔值。')
                config = with_artifact_sha(self.server.cli.project, body['config'])
                credentials = body.get('credentials') if include else None
                self._send(200, {'filename': 'cluster-vars.env',
                                 'text': export_env(config, credentials, include)})
            else:
                shape(body, ['config']); config = normalize_config(body['config'])
                self._send(200, self.server.cli.run('plan' if route == '/api/plan' else 'config-check', config))
            return
        raise APIError(404, 'not_found', '没有此接口，或当前服务未启用此功能。')

    def _execute(self, operation, body):
        # Import only when explicitly connected: configuration-only help/startup
        # must not depend on execution modules or open a privileged connection.
        from execution_client import ExecutionError
        try:
            return self.server.execution.request(operation, body)
        except ExecutionError as error:
            raise APIError(error.status, error.code, error.message) from None

    def _jobs(self, route):
        if self.command == 'POST' and route == '/api/jobs/preview':
            body = self._body()
            if set(body) not in ({'config'}, {'config', 'stage'}):
                raise APIError(400, 'invalid_request', '预览字段不完整或包含不支持的字段。')
            stage = body.get('stage', 'all')
            self._send(200, self._execute('preview', {'config': normalize_config(body['config']), 'stage': stage})); return
        if route == '/api/jobs':
            if self.command == 'GET':
                self._send(200, self._execute('list', {})); return
            if self.command == 'POST':
                body = self._body()
                # Must match ExecutionService.submit and the page payload: the
                # checkbox acknowledgement is the boolean 'acknowledged'; there is
                # no free-text confirmation field, and 'debug' selects the log level.
                required = {'request_id', 'plan_id', 'config_sha256', 'acknowledged', 'credentials', 'debug'}
                if not required <= set(body) or set(body) - required - {'stage'}:
                    raise APIError(400, 'invalid_request', '请求字段不完整或包含不支持的字段。')
                body.setdefault('stage', 'all')
                # The executor owns acknowledgement, credentials and concurrency
                # decisions. No credential is saved in the local draft store.
                self._send(200, self._execute('submit', body)); return
        matched = re.fullmatch(r'/api/jobs/(' + UUID.pattern[1:-1] + r')(?:(/stop)|(/logs)(?:\?offset=([0-9]{1,16}))?)?', route)
        if matched:
            identifier, stop, logs, offset = matched.groups()
            if self.command == 'GET' and not stop:
                if logs:
                    self._send(200, self._execute('logs', {'id': identifier, 'offset': int(offset or '0')}))
                else:
                    self._send(200, self._execute('get', {'id': identifier}))
                return
            if self.command == 'POST' and stop:
                body = self._body(); shape(body, [])
                self._send(200, self._execute('stop', {'id': identifier})); return
        raise APIError(404, 'not_found', '没有此任务接口。')

    def _handle(self):
        try:
            self._dispatch()
        except APIError as error:
            self._send(error.status, {'error': {'code': error.code, 'message': error.message}})
        except ModelError as error:
            self._send(400, {'error': {'code': 'invalid_config', 'message': str(error)}})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception:
            self._send(500, {'error': {'code': 'internal_error', 'message': '本地服务发生错误，任务结果未确认；若已提交部署，请按原任务 ID 核对，勿重复创建任务。'}})

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_OPTIONS = _handle
    do_HEAD = _handle


def make_server(project_root, data_dir, port=0, token=None, execution=None):
    project = Path(project_root).resolve()
    if not (project / 'deploy.sh').is_file():
        raise ValueError('项目缺少 deploy.sh。')
    if type(port) is not int or not 0 <= port <= 65535:
        raise ValueError('端口无效。')
    server = WebServer(('127.0.0.1', port), Handler, bind_and_activate=False)
    try:
        server.drafts = DraftStore(data_dir, project)
        server.cli = ReadOnlyCLI(project)
        server.execution = execution
        server.web_token = token if token is not None else secrets.token_urlsafe(32)
        if not isinstance(server.web_token, str) or not server.web_token.isascii() or len(server.web_token) < 16:
            raise ValueError('会话令牌格式无效。')
        server.server_bind(); server.server_activate()
        return server
    except BaseException:
        server.server_close()
        raise


def ssh_tunnel_hint(port, env=None, user=None):
    source = os.environ if env is None else env
    conn = (source.get('SSH_CONNECTION') or '').strip()
    client = (source.get('SSH_CLIENT') or '').strip()
    tty = (source.get('SSH_TTY') or '').strip()
    if not (conn or client or tty):
        return ''
    host_ip = '<控制端IP>'
    port_opt = ''
    if conn:
        parts = conn.split()
        if len(parts) >= 3 and parts[2]:
            host_ip = parts[2]
        if len(parts) >= 4 and parts[3].isdigit() and parts[3] != '22':
            port_opt = '-p %s ' % parts[3]
    if not user:
        try:
            user = pwd.getpwuid(os.getuid()).pw_name
        except KeyError:
            user = source.get('USER') or '<用户名>'
    return (
        '检测到远程 SSH 会话；因工作台仅监听 127.0.0.1，请在本机终端执行以下端口转发命令后再打开上述链接：\n'
        '  ssh -N %s-L %s:127.0.0.1:%s %s@%s' % (port_opt, port, port, user, host_ip)
    )


def main():
    parser = argparse.ArgumentParser(description='本机 Web 配置工作台；显式连接管理员执行器后可提交首次安装。')
    parser.add_argument('--data-dir', required=True, help='项目外的专用草稿目录，新目录或权限 0700 的空目录')
    parser.add_argument('--port', type=int, default=8765, help='仅监听 127.0.0.1，默认 8765；0 自动分配')
    parser.add_argument('--executor-socket', help='可选：管理员启动的本机执行器 Unix socket 绝对路径；省略时只提供配置功能')
    args = parser.parse_args()
    if os.getuid() == 0:
        parser.error('请以普通用户启动 Web；需要部署时连接独立的管理员执行器。')
    try:
        execution = None
        if args.executor_socket:
            from execution_client import ExecutorClient
            execution = ExecutorClient(args.executor_socket)
        server = make_server(Path(__file__).resolve().parents[1], args.data_dir, args.port, execution=execution)
    except (ValueError, OSError, APIError) as error:
        parser.error(str(error))
    label = '已配置本机执行器连接；部署须预览并确认。' if execution is not None else '仅本机配置工作台，无部署执行能力。'
    print(label + '使用当前终端的临时链接进入；不要转发含 token 的链接。', flush=True)
    print('http://127.0.0.1:%s/#token=%s' % (server.server_port, server.web_token), flush=True)
    hint = ssh_tunnel_hint(server.server_port)
    if hint:
        print(hint, flush=True)
    try:
        server.serve_forever(poll_interval=.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
