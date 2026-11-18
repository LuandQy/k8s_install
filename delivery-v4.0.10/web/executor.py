#!/usr/bin/env python3
"""Explicit root-only, local Unix-socket execution service."""
import argparse
import os
from pathlib import Path
import pwd
import signal
import socket
import socketserver
import stat
import struct
import sys
import threading

from execution import (ExecutionError, ExecutionService, MAX_REQUEST, MAX_RESPONSE,
                       encoded, fail, protected_path, shape, strict_json)


class RPCHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(20)
        try:
            _, uid, _ = struct.unpack('3i', self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            if uid != self.server.service.allowed_uid:
                fail(403, 'forbidden_peer', '该本机用户未获执行器授权。')
            raw = bytearray()
            while b'\n' not in raw:
                block = self.request.recv(min(8192, MAX_REQUEST + 1 - len(raw)))
                if not block:
                    fail(400, 'invalid_request', '请求必须以换行结束。')
                raw.extend(block)
                if len(raw) > MAX_REQUEST:
                    fail(413, 'too_large', '执行器请求超过 256 KiB。')
            line, rest = bytes(raw).split(b'\n', 1)
            if rest:
                fail(400, 'invalid_request', '每次连接仅接受一个请求。')
            try:
                value = strict_json(line.decode('utf-8'))
            except (ValueError, UnicodeError, RecursionError):
                fail(400, 'invalid_json', '请求必须为有效且不含重复字段的 UTF-8 JSON。')
            shape(value, ('op', 'body'))
            if not isinstance(value['op'], str):
                fail(400, 'invalid_request', '操作名称必须为文本。')
            reply = {'ok': True, 'result': self.server.service.request(value['op'], value['body'])}
        except ExecutionError as error:
            reply = {'ok': False, 'error': {'status': error.status, 'code': error.code, 'message': error.message}}
        except Exception:
            reply = {'ok': False, 'error': {'status': 500, 'code': 'executor_error',
                                           'message': '执行器请求结果未确认；请按任务编号核查，不要重复部署。'}}
        try:
            payload = encoded(reply) + b'\n'
            if len(payload) > MAX_RESPONSE:
                payload = encoded({'ok': False, 'error': {'status': 502, 'code': 'response_limit',
                                                         'message': '响应超过限制，请按单个任务查看。'}}) + b'\n'
            self.request.sendall(payload)
        except (OSError, ValueError):
            pass


class RPCServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self, socket_path, service, socket_gid=None):
        self.service = service
        self.slot = threading.BoundedSemaphore(16)
        self.socket_path = Path(socket_path)
        self.socket_inode = None
        parent = protected_path(self.socket_path.parent, service.trusted_uid, directory=True, absent=True)
        new_parent = not parent.exists()
        parent.mkdir(mode=0o711, parents=True, exist_ok=True)
        if new_parent:
            parent.chmod(0o711)
        protected_path(parent, service.trusted_uid, directory=True)
        if service.trusted_uid == 0:
            for directory in (parent,) + tuple(parent.parents):
                if not directory.stat().st_mode & 0o001:
                    fail(400, 'inaccessible_socket', 'socket 的全部父目录须允许普通用户穿越；请使用专用 /run 目录。')
        if len(os.fsencode(str(self.socket_path))) >= 104:
            fail(400, 'invalid_socket', 'Unix socket 路径过长。')
        if self.socket_path.exists() or self.socket_path.is_symlink():
            info = self.socket_path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != service.trusted_uid or info.st_mode & 0o007:
                fail(400, 'invalid_socket', '现有 socket 路径类型、所有权或权限不安全。')
            # Data lock is already held, but a different data-root worker could
            # own this pathname. Never unlink a live listener.
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.settimeout(1)
                probe.connect(str(self.socket_path))
            except ConnectionRefusedError:
                self.socket_path.unlink()
            except OSError:
                fail(409, 'socket_busy', '无法确认旧 socket 已停止，拒绝覆盖。')
            else:
                fail(409, 'socket_busy', 'socket 已有执行器监听，拒绝覆盖。')
            finally:
                probe.close()
        old_umask = os.umask(0o177)
        try:
            super().__init__(str(self.socket_path), RPCHandler)
            if socket_gid is not None:
                os.chown(str(self.socket_path), service.trusted_uid, socket_gid)
            os.chmod(str(self.socket_path), 0o660)
            self.socket_inode = self.socket_path.lstat().st_ino
        finally:
            os.umask(old_umask)

    def process_request(self, request, client_address):
        if not self.slot.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slot.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slot.release()

    def handle_error(self, request, client_address):
        # Never print request, traceback, credentials or environment to stderr.
        pass

    def server_close(self):
        super().server_close()
        try:
            if self.socket_inode is not None and self.socket_path.lstat().st_ino == self.socket_inode:
                self.socket_path.unlink()
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser(description='本机 Web 部署执行器；只支持显式确认的新环境首装。')
    parser.add_argument('--project-root', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--data-dir', default='/var/lib/rise-web-executor')
    parser.add_argument('--work-root', default='/data/rise-web')
    parser.add_argument('--socket', default='/run/rise-web-executor/control.sock')
    parser.add_argument('--allowed-uid', type=int, required=True, help='唯一获授权的普通用户 UID')
    args = parser.parse_args()
    if os.getuid() != 0 or os.geteuid() != 0:
        parser.error('执行器必须由管理员以 root 启动；普通用户 Web 不会自行提权。')
    if args.allowed_uid <= 0:
        parser.error('--allowed-uid 必须为经管理员授权的非 root 用户 UID。')
    service = server = None
    try:
        account = pwd.getpwuid(args.allowed_uid)
        service = ExecutionService(args.project_root, args.data_dir, args.work_root, args.allowed_uid)
        server = RPCServer(args.socket, service, socket_gid=account.pw_gid)
        stopping = threading.Event()
        def stop(_signum, _frame):
            if not stopping.is_set():
                stopping.set()
                # shutdown must run outside the serve_forever thread. close()
                # requests stage-boundary stop and waits without killing jobs.
                threading.Thread(target=server.shutdown, daemon=True).start()
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
        print('执行器已就绪；仅允许指定本机 UID；关闭时等待当前阶段安全结束。', flush=True)
        server.serve_forever(poll_interval=0.2)
        return 0
    except ExecutionError as error:
        print(error.message, file=sys.stderr)
        return 1
    except (OSError, KeyError, ValueError):
        print('执行器启动失败；请核查受信任发布目录、用户、私有数据目录和 socket。', file=sys.stderr)
        return 1
    finally:
        if service:
            service.close()
        if server:
            server.server_close()


if __name__ == '__main__':
    sys.exit(main())
