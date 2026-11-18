"""Typed phase-one drafts and a non-executing, restricted Bash-env importer.

This module never invokes a shell, probes nodes, opens user-selected paths, or
reads deployment state. Cross-field deployment validation belongs to the existing
CLI. The grammar intentionally accepts a subset of Bash literal assignments;
unknown input is rejected instead of sourced, guessed, or silently discarded.
"""
import copy
import json
import re
import unicodedata
from pathlib import Path

_SCHEMA_PATH = Path(__file__).with_name('schema.json')
_VERSION_RE = re.compile(r'v(\d+)\.(\d+)\.(\d+)')
_VERSION_FIELD = re.compile(r'^\s*kube_version:\s*["\']?(v\d+\.\d+\.\d+)["\']?\s*(?:#.*)?$', re.MULTILINE)
MAX_ENV_BYTES = 256 * 1024
MAX_NODES = 32
MAX_STRING = 2048
_PATH_KEYS = frozenset({
    'WORK_DIR', 'STATE_DIR', 'PACKAGE_WORK_DIR', 'SSH_KEY', 'SSH_KNOWN_HOSTS',
    'PKI_ROOT_CERT', 'PKI_ROOT_KEY',
    'HARBOR_SOURCE_DIR', 'HARBOR_CA', 'HARBOR_CERT', 'HARBOR_KEY', 'BOOTSTRAP_ARCHIVE',
    'LOCAL_PATH', 'NFS_PATH', 'ARTIFACT_FILE', 'data_path', 'device',
})
_DIGEST_KEYS = frozenset({'ARTIFACT_SHA256', 'SSH_KNOWN_HOSTS_SHA256'})
_CONTROL = re.compile(r'[\x00-\x1f\x7f-\x9f]')
_SAFE_PATH = re.compile(r'/[a-zA-Z0-9_./-]+\Z')
_NAME = re.compile(r'[A-Z_][A-Z0-9_]{0,63}\Z')


class ModelError(ValueError):
    """A user-facing error without echoed submitted values or shell source."""


def discover_kubernetes_versions(root=None):
    """The configs/vX.Y.Z.yaml files are the only version registry."""
    directory = (Path(root) / 'configs') if root is not None else _SCHEMA_PATH.parent.parent / 'configs'
    if not directory.is_dir():
        raise ModelError('缺少 configs 版本目录: %s' % directory)
    versions = []
    for path in sorted(directory.glob('v*.yaml')):
        match = _VERSION_RE.fullmatch(path.stem)
        if not match:
            continue
        declared = _VERSION_FIELD.search(path.read_text(encoding='utf-8'))
        if not declared:
            raise ModelError('版本文件缺少 kube_version: %s' % path.name)
        if declared.group(1) != path.stem:
            raise ModelError('文件名与 kube_version 不一致: %s' % path.name)
        versions.append(path.stem)
    if not versions:
        raise ModelError('configs/ 下没有可用的 Kubernetes 版本文件')
    if len(set(versions)) != len(versions):
        raise ModelError('configs/ 存在重复 Kubernetes 版本')
    def key(value):
        return tuple(int(part) for part in _VERSION_RE.fullmatch(value).groups())
    return sorted(set(versions), key=key, reverse=True)


def schema():
    """Return fresh metadata with versions discovered from configs/."""
    spec = json.loads(_SCHEMA_PATH.read_text(encoding='utf-8'))
    versions = discover_kubernetes_versions()
    for field in spec['settings']:
        if field['key'] == 'KUBE_VERSION':
            field['enum'] = versions
            field['default'] = versions[0]
            field['option_labels'] = {value: 'Kubernetes ' + value[1:] for value in versions}
            field['option_help'] = {value: '来自 configs/%s.yaml；离线制品仍需按版本核验。' % value for value in versions}
            break
    else:
        raise ModelError('schema 缺少 KUBE_VERSION 字段')
    return spec


def default_config():
    """A sample topology; addresses must be changed before any future deployment."""
    spec = schema()
    return {
        'schema_version': 1,
        'settings': {f['key']: copy.deepcopy(f['default']) for f in spec['settings']},
        'nodes': copy.deepcopy(spec['default_nodes']),
    }


def _field(value, spec, location):
    kind = spec['type']
    if kind == 'string':
        if (not isinstance(value, str) or len(value) > MAX_STRING or _CONTROL.search(value)
                or any(unicodedata.category(c) in ('Cc', 'Cf', 'Cs') for c in value)):
            raise ModelError(location + ' 必须是长度不超过 2048 的单行文本')
        if spec['key'] in _PATH_KEYS and value:
            if not _SAFE_PATH.fullmatch(value) or '..' in value:
                raise ModelError(location + ' 只接受不含空格、中文或 .. 的绝对路径')
        if spec['key'] in _DIGEST_KEYS and value:
            if not re.fullmatch('[0-9a-f]{64}', value):
                raise ModelError(location + ' 必须是 64 位小写 SHA256 或留空')
        if spec['key'] == 'password_env' and value and not _NAME.fullmatch(value):
            raise ModelError(location + ' 只能是大写密码变量名，不接受密码值')
    elif kind == 'integer':
        if type(value) is not int or not -2147483648 <= value <= 2147483647:
            raise ModelError(location + ' 必须是 32 位整数')
        if (('minimum' in spec and value < spec['minimum'])
                or ('maximum' in spec and value > spec['maximum'])):
            raise ModelError(location + ' 必须在 %s–%s 之间' % (spec.get('minimum'), spec.get('maximum')))
    elif kind == 'boolean':
        if type(value) is not bool:
            raise ModelError(location + ' 必须是 JSON 布尔值')
    elif kind == 'array':
        if not isinstance(value, list) or len(value) > len(spec.get('enum', [])):
            raise ModelError(location + ' 必须是角色数组')
        if any(not isinstance(v, str) or v not in spec['enum'] for v in value):
            raise ModelError(location + ' 含不支持的角色')
        if len(set(value)) != len(value):
            raise ModelError(location + ' 不能包含重复角色')
        return list(value)
    else:
        raise RuntimeError('Unsupported schema field type')
    if 'enum' in spec and value not in spec['enum']:
        raise ModelError(location + ' 不属于支持的选项')
    return value


def normalize_config(config):
    """Validate structure/types and complete defaults, without deployment I/O.

    Empty text and an empty node list may be saved as an incomplete draft. Shape,
    path syntax, enum, control-character and serialization boundaries are checked
    here; e.g. network overlap, role relationships and missing endpoints are left
    to the shared Bash validator when the user requests validation or planning.
    """
    if not isinstance(config, dict) or set(config) != {'schema_version', 'settings', 'nodes'}:
        raise ModelError('配置只能包含 schema_version、settings 和 nodes')
    if type(config['schema_version']) is not int or config['schema_version'] != 1:
        raise ModelError('仅支持配置 schema_version=1')
    values, nodes = config['settings'], config['nodes']
    if not isinstance(values, dict) or not isinstance(nodes, list) or len(nodes) > MAX_NODES:
        raise ModelError('settings 必须为对象，nodes 必须为不超过 32 项的数组')
    spec = schema()
    fields = {f['key']: f for f in spec['settings']}
    if set(values) - fields.keys():
        raise ModelError('配置包含未知或禁止的字段；不接受密码值、运行参数或自定义 Bash 变量')
    normalized = {}
    for key, field in fields.items():
        normalized[key] = _field(values.get(key, copy.deepcopy(field['default'])), field, key)
    node_fields = {f['key']: f for f in spec['node_fields']}
    normalized_nodes = []
    for index, node in enumerate(nodes, 1):
        if not isinstance(node, dict) or set(node) - node_fields.keys():
            raise ModelError('节点 %s 包含未知字段或不是对象' % index)
        result = {}
        for key, field in node_fields.items():
            value = _field(node.get(key, copy.deepcopy(field['default'])), field,
                           '节点 %s 的 %s' % (index, key))
            if isinstance(value, str) and '|' in value:
                raise ModelError('节点 %s 的 %s 不能包含列分隔符' % (index, key))
            result[key] = value
        normalized_nodes.append(result)
    return {'schema_version': 1, 'settings': normalized, 'nodes': normalized_nodes}


class _LiteralEnv:
    """Small finite-state parser; never use Bash, eval, or exec to parse input."""

    def __init__(self, text):
        if not isinstance(text, str):
            raise ModelError('env 内容必须为文本')
        try:
            length = len(text.encode('utf-8'))
        except UnicodeError:
            raise ModelError('env 必须为有效 UTF-8 文本') from None
        if length > MAX_ENV_BYTES:
            raise ModelError('env 超过 256 KiB 限制')
        # Windows line endings are accepted; lone CR and other control characters
        # are not. Newlines/tabs in values are validated after literal parsing.
        self.text = text.replace('\r\n', '\n')
        if re.search(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]', self.text):
            raise ModelError('env 含不支持的控制字符')
        self.pos = 0

    def fail(self, message):
        line = self.text.count('\n', 0, self.pos) + 1
        raise ModelError('env 第 %s 行：%s' % (line, message))

    def quoted(self, quote, ansi=False):
        self.pos += 1
        result = []
        escapes = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', "'": "'", '"': '"'}
        while self.pos < len(self.text):
            c = self.text[self.pos]
            self.pos += 1
            if c == quote:
                return ''.join(result)
            if c == '\\' and (ansi or quote == '"'):
                if self.pos == len(self.text) or self.text[self.pos] == '\n':
                    self.fail('不支持反斜杠续行')
                following = self.text[self.pos]
                self.pos += 1
                if ansi:
                    if following not in escapes:
                        self.fail('ANSI-C 引号只支持换行、制表、回车、引号和反斜杠转义')
                    result.append(escapes[following])
                else:
                    if following not in '\\"$`':
                        self.fail('双引号含不支持的转义')
                    result.append(following)
            elif quote == '"' and c in '$`':
                self.fail('不支持变量展开或命令替换')
            else:
                result.append(c)
        self.fail('引号未闭合')

    def value(self):
        parts = []
        while self.pos < len(self.text):
            c = self.text[self.pos]
            if c in ' \t\n':
                break
            if c in "'\"":
                parts.append(self.quoted(c))
            elif self.text.startswith("$'", self.pos):
                self.pos += 1
                parts.append(self.quoted("'", ansi=True))
            elif c == '\\':
                self.pos += 1
                if self.pos == len(self.text) or self.text[self.pos] == '\n':
                    self.fail('不支持反斜杠续行')
                parts.append(self.text[self.pos])
                self.pos += 1
            elif c in '$`;&|<>(){}[]#':
                self.fail('只接受独立的字面量赋值，不接受 Shell 表达式或命令')
            else:
                parts.append(c)
                self.pos += 1
        return ''.join(parts)

    def assignments(self):
        values = {}
        while self.pos < len(self.text):
            while self.pos < len(self.text) and self.text[self.pos] in ' \t\n':
                self.pos += 1
            if self.pos == len(self.text):
                break
            if self.text[self.pos] == '#':
                end = self.text.find('\n', self.pos)
                self.pos = len(self.text) if end < 0 else end + 1
                continue
            start = self.pos
            while self.pos < len(self.text) and self.text[self.pos] not in '= \t\n':
                self.pos += 1
            key = self.text[start:self.pos]
            if not _NAME.fullmatch(key) or self.pos >= len(self.text) or self.text[self.pos] != '=':
                self.fail('需要大写变量名紧接等号，不支持 export、命令或复合语句')
            if key in values:
                self.fail('不允许重复变量赋值')
            self.pos += 1
            value = self.value()
            while self.pos < len(self.text) and self.text[self.pos] in ' \t':
                self.pos += 1
            if self.pos < len(self.text) and self.text[self.pos] == '#':
                end = self.text.find('\n', self.pos)
                self.pos = len(self.text) if end < 0 else end
            if self.pos < len(self.text) and self.text[self.pos] != '\n':
                self.fail('每行只接受一个赋值及可选注释')
            values[key] = value
            if self.pos < len(self.text):
                self.pos += 1
        return values


def _from_env_value(value, field):
    kind = field['type']
    if kind == 'boolean':
        if value not in ('true', 'false'):
            raise ModelError(field['key'] + ' 只接受 true/false')
        return value == 'true'
    if kind == 'integer':
        if not re.fullmatch(r'-?[0-9]{1,10}', value):
            raise ModelError(field['key'] + ' 需要十进制整数')
        return int(value, 10)
    return value


_CLI_ONLY_KEYS = frozenset({
    'ZONE', 'PKI_ROOT_CERT', 'PKI_ROOT_KEY', 'SSH_KNOWN_HOSTS', 'SSH_KNOWN_HOSTS_SHA256',
})


def import_env(text):
    """Parse strict literal assignments, including wizard %q node serialization.

    NODES must be explicitly present (an empty NODES is an incomplete draft).
    Missing known settings use the schema's CLI-compatible defaults. Password
    values, NONINTERACTIVE, arbitrary variables and duplicate assignments fail.
    CLI-only state keys (ZONE, PKI_ROOT_*, SSH_KNOWN_HOSTS*) are syntax-checked
    and ignored so CLI state receipts can be imported into Web without error.
    """
    values = _LiteralEnv(text).assignments()
    spec = schema()
    fields = {f['key']: f for f in spec['settings']}
    if set(values) - (set(fields) | {'NODES'} | _CLI_ONLY_KEYS):
        raise ModelError('env 含未知或禁止变量；不接收密码值、运行参数或自定义变量')
    for cli_key in set(values) & _CLI_ONLY_KEYS:
        raw_val = values[cli_key]
        if cli_key in _PATH_KEYS and raw_val:
            if not _SAFE_PATH.fullmatch(raw_val) or '..' in raw_val:
                raise ModelError(cli_key + ' 只接受不含空格、中文或 .. 的绝对路径')
        elif cli_key in _DIGEST_KEYS and raw_val:
            if not re.fullmatch('[0-9a-f]{64}', raw_val):
                raise ModelError(cli_key + ' 必须是 64 位小写 SHA256 或留空')
    if 'NODES' not in values:
        raise ModelError('env 必须显式包含 NODES；不会猜测或复用默认拓扑')
    settings = {key: _from_env_value(value, fields[key]) for key, value in values.items()
                if key != 'NODES' and key not in _CLI_ONLY_KEYS}
    nodes = []
    for line in values['NODES'].split('\n'):
        if not line.strip():
            continue
        cells = line.split('|')
        if len(cells) != 13:
            raise ModelError('NODES 每个非空行必须有完整的 13 列')
        node = {}
        for value, field in zip(cells, spec['node_fields']):
            node[field['key']] = value.split(',') if field['key'] == 'roles' and value else (
                [] if field['key'] == 'roles' else _from_env_value(value, field))
        nodes.append(node)
    return normalize_config({'schema_version': 1, 'settings': settings, 'nodes': nodes})


def validate_topology(config):
    """Validate Master/Etcd co-located odd-quorum HA constraints and VIP rules."""
    config = normalize_config(config)
    settings = config['settings']
    nodes = config['nodes']
    components = settings.get('COMPONENTS', 'all')
    if settings.get('VALIDATION_SCOPE', 'cluster') == 'workers':
        return config
    if not nodes:
        raise ModelError('节点清单不能为空')
    masters = 0
    etcds = 0
    for node in nodes:
        roles = set(node.get('roles') or [])
        has_master = 'control_plane' in roles
        has_etcd = 'etcd' in roles
        if has_etcd and not has_master:
            raise ModelError('节点 %s 不能单独挂载 etcd；etcd 必须与 master 同机部署' % (node.get('name') or ''))
        if has_master:
            masters += 1
        if has_etcd:
            etcds += 1
    if components == 'harbor':
        return config
    if etcds > 0 and etcds != masters:
        raise ModelError('Master 与 Etcd 必须同机一一对应（当前 Master=%s，Etcd=%s）' % (masters, etcds))
    if masters < 1 or masters % 2 == 0:
        raise ModelError('Master 与 Etcd 节点数量必须为 1、3、5 等正奇数（当前为 %s），偶数节点存在高可用脑裂风险' % masters)
    if masters >= 3 and settings.get('ENDPOINT_TYPE') == 'local':
        raise ModelError('多 Master 高可用（%s 节点）必须使用 kube-vip、haproxy 或 external 入口' % masters)
    if settings.get('ENDPOINT_TYPE') == 'haproxy' and settings.get('ENDPOINT_ADDRESS', '').strip():
        raise ModelError('haproxy 内置负载均衡模式无需且禁止填写 ENDPOINT_ADDRESS')
    if settings.get('ENDPOINT_TYPE') in ('kube-vip', 'external') and not settings.get('ENDPOINT_ADDRESS', '').strip():
        raise ModelError('%s 入口模式必须填写 ENDPOINT_ADDRESS' % settings.get('ENDPOINT_TYPE'))
    return config


def _quote(value):
    # POSIX/Bash concatenated literals; embedded apostrophes never leave a word.
    return "'" + value.replace("'", "'\\''") + "'"


def export_env(config, credentials=None, include_credentials=False):
    """Emit inert literal assignments only, for deliberate later CLI use.

    Passwords are never part of a draft. When the operator explicitly asks for
    them, they are appended here as inert assignments (HARBOR_PASSWORD and the
    per-node password_env variables) so a reviewed CLI run can reuse the form
    values. The caller must not persist the result without protecting it.
    """
    config = normalize_config(config)
    lines = [
        '# Web 配置草稿；尚未授权执行，现场条件仍须另行核验。',
        '# 不含私钥正文；不得覆盖已有工作流绑定的现场配置。',
    ]
    for key, value in config['settings'].items():
        if key == 'STATE_DIR' and value == '':
            continue
        if isinstance(value, bool):
            value = 'true' if value else 'false'
        elif isinstance(value, int):
            value = str(value)
        lines.append(key + '=' + _quote(value))
    columns = [f['key'] for f in schema()['node_fields']]
    rows = []
    for node in config['nodes']:
        cells = []
        for key in columns:
            value = node[key]
            cells.append(','.join(value) if isinstance(value, list) else str(value))
        rows.append('|'.join(cells))
    lines.append('NODES=' + _quote('\n'.join(rows)))
    if include_credentials:
        lines.extend(['# 以下密码来自表单且仅在本次导出中生成；请按凭据保管，不要随公共包分发。',])
        _append_credentials(lines, config, credentials)
    return '\n'.join(lines) + '\n'


def _append_credentials(lines, config, credentials):
    """Append password variables requested by an explicit export toggle."""
    if not isinstance(credentials, dict):
        raise ModelError('导出密码需要 credentials 对象')
    allowed = {'harbor'} | {'node:' + node['name'] for node in config['nodes'] if node['name']}
    unknown = set(credentials) - allowed
    if unknown:
        raise ModelError('导出密码包含未知凭据键；只接受 harbor 与当前节点名称')
    harbor = credentials.get('harbor', '')
    if not isinstance(harbor, str) or '\n' in harbor or '\r' in harbor:
        raise ModelError('Harbor 密码必须是单行文本')
    if harbor:
        lines.append('HARBOR_PASSWORD=' + _quote(harbor))
    for node in config['nodes']:
        value = credentials.get('node:' + node['name'], '') if node['name'] else ''
        if not value:
            continue
        if not isinstance(value, str) or '\n' in value or '\r' in value:
            raise ModelError('节点 %s 的密码必须是单行文本' % node['name'])
        variable = node.get('password_env') or ''
        if not variable:
            raise ModelError('节点 %s 未填写密码变量名，无法导出密码' % node['name'])
        lines.append(variable + '=' + _quote(value))
