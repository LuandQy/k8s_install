"""Bounded single-request RPC to the administrator's local executor.

The ordinary-user HTTP process never launches sudo or deployment commands.
Connection failures are ambiguous after submission; there is no automatic retry.
"""
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import time

MAX_REQUEST = 256 * 1024
MAX_RESPONSE = 1024 * 1024
OPERATIONS = frozenset(('capabilities', 'preview', 'submit', 'list', 'get', 'logs', 'stop', 'ledger', 'artifact_sha256', 'probe_nodes', 'clusters', 'expand_workers'))
UNCONFIRMED = '无法确认执行器结果；若已提交部署，请按原任务 ID 核对，勿重复创建任务。'


class ExecutionError(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message
        super().__init__(message)


def _strict_json(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise ValueError('duplicate key')
            value[key] = item
        return value
    def nonfinite(_):
        raise ValueError('nonfinite value')
    return json.loads(raw.decode('utf-8'), object_pairs_hook=pairs, parse_constant=nonfinite)


class ExecutorClient:
    def __init__(self, socket_path, timeout=120):
        raw = Path(socket_path)
        if not raw.is_absolute() or '..' in raw.parts or '\x00' in str(raw):
            raise ValueError('执行器 socket 必须使用无上级跳转的绝对路径。')
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= 120:
            raise ValueError('执行器连接超时须为 0–120 秒。')
        self.path, self.timeout = raw, timeout

    def _check_path(self):
        # No resolve(): every component must remain a non-symlink, root-owned
        # directory that an ordinary local user cannot replace or populate.
        try:
            for parent in reversed(self.path.parents):
                info = parent.lstat()
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                    raise ValueError('unsafe parent')
            info = self.path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o007:
                raise ValueError('unsafe socket')
            return info.st_dev, info.st_ino
        except (OSError, ValueError):
            raise ExecutionError(503, 'unsafe_executor_socket', '执行器 socket 不存在，或所有者、目录及文件权限不符合管理员保护要求。') from None

    @staticmethod
    def _decode(raw):
        try:
            reply = _strict_json(raw)
            if not isinstance(reply, dict) or type(reply.get('ok')) is not bool:
                raise ValueError('invalid response')
            if reply['ok']:
                if set(reply) != {'ok', 'result'} or not isinstance(reply['result'], dict):
                    raise ValueError('invalid result')
                return reply['result']
            if set(reply) != {'ok', 'error'}:
                raise ValueError('invalid error')
            error = reply['error']
            if (not isinstance(error, dict) or set(error) != {'status', 'code', 'message'}
                    or type(error['status']) is not int or not 400 <= error['status'] <= 599
                    or not isinstance(error['code'], str) or not re.fullmatch(r'[a-z][a-z0-9_]{0,63}', error['code'])
                    or not isinstance(error['message'], str) or not 1 <= len(error['message']) <= 1000
                    or any(ord(char) < 32 or 0x7f <= ord(char) <= 0x9f for char in error['message'])):
                raise ValueError('invalid error fields')
            raise ExecutionError(error['status'], error['code'], error['message'])
        except (ValueError, TypeError, UnicodeError, RecursionError):
            raise ExecutionError(502, 'invalid_executor_response', UNCONFIRMED) from None

    def request(self, operation, body=None):
        if not isinstance(operation, str) or operation not in OPERATIONS or body is not None and not isinstance(body, dict):
            raise ExecutionError(400, 'invalid_execution_request', '不支持的执行器操作或请求格式。')
        try:
            payload = json.dumps({'op': operation, 'body': body if body is not None else {}},
                                 ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8') + b'\n'
        except (TypeError, ValueError, UnicodeError, RecursionError):
            raise ExecutionError(400, 'invalid_execution_request', '执行器请求格式无效。') from None
        if len(payload) > MAX_REQUEST:
            raise ExecutionError(413, 'execution_request_too_large', '执行器请求超过 256 KiB 限制。')
        identity = self._check_path()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                deadline = time.monotonic() + self.timeout
                def remaining():
                    left = deadline - time.monotonic()
                    if left <= 0:
                        raise TimeoutError('executor deadline')
                    connection.settimeout(left)
                remaining()
                connection.connect(str(self.path))
                if not hasattr(socket, 'SO_PEERCRED'):
                    raise ExecutionError(503, 'unsupported_peer_check', '当前系统不支持执行器身份校验。')
                _, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i')))
                if uid != 0 or self._check_path() != identity:
                    raise ExecutionError(503, 'executor_identity_rejected', '执行器身份校验失败，未发送请求。')
                # Send credentials only after confirming the privileged peer.
                remaining()
                connection.sendall(payload)
                output = bytearray()
                while len(output) <= MAX_RESPONSE:
                    remaining()
                    chunk = connection.recv(min(65536, MAX_RESPONSE + 1 - len(output)))
                    if not chunk:
                        raise ExecutionError(502, 'incomplete_executor_response', UNCONFIRMED)
                    output.extend(chunk)
                    if len(output) > MAX_RESPONSE:
                        raise ExecutionError(502, 'executor_response_too_large', UNCONFIRMED)
                    if b'\n' in output:
                        line, trailing = bytes(output).split(b'\n', 1)
                        if trailing:
                            raise ExecutionError(502, 'invalid_executor_response', UNCONFIRMED)
                        return self._decode(line)
        except (OSError, struct.error):
            raise ExecutionError(503, 'executor_unavailable', UNCONFIRMED) from None
