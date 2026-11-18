#!/usr/bin/env python3
"""Validate or exclusively create a controller deployment key; never replace it.

Only public key material reaches stdout. Private keys are read by ssh-keygen via
an already checked file descriptor, without an interactive passphrase prompt.
"""
import base64
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile


class PolicyError(Exception):
    pass


def fail(message):
    raise PolicyError(message)


def public_parts(data):
    try:
        text = data.decode('utf-8').strip()
        if '\n' in text or '\r' in text or len(text) > 16384:
            fail('public key must contain exactly one supported key')
        parts = text.split()
        if len(parts) < 2 or not re.fullmatch(r'ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)', parts[0]):
            fail('public key type or format is unsupported')
        raw = base64.b64decode(parts[1], validate=True)
        length = struct.unpack('>I', raw[:4])[0]
        if raw[4:4 + length].decode('ascii') != parts[0]:
            fail('public key type does not match its data')
        return parts[0], raw, parts[0] + ' ' + base64.b64encode(raw).decode('ascii')
    except (ValueError, UnicodeError, struct.error, IndexError):
        fail('public key format is invalid')


def open_parent(path, create):
    if not re.fullmatch(r'/[a-zA-Z0-9_./-]+', path) or '..' in path or path.endswith('/'):
        fail('SSH_KEY must be a plain absolute file path')
    pieces = Path(path).parts[1:]
    if not pieces:
        fail('SSH_KEY must name a file')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in pieces[:-1]:
            try:
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    fail('key mode requires an existing private key')
                os.mkdir(name, 0o700, dir_fd=fd)
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
            fail('SSH_KEY parent must belong to this user and must not be group/world writable')
        return fd, pieces[-1]
    except BaseException:
        os.close(fd)
        raise


def checked_file(parent, name, private):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            fail('key file must be a single-link regular file owned by this user')
        mode = stat.S_IMODE(info.st_mode)
        if private and mode not in (0o400, 0o600):
            fail('private key permissions must be 0400 or 0600')
        if not private and mode & 0o022:
            fail('public key must not be group/world writable')
        if not 0 < info.st_size <= (1024 * 1024 if private else 16384):
            fail('key file is empty or exceeds the size limit')
        return fd
    except BaseException:
        os.close(fd)
        raise


def derive(private_fd):
    try:
        result = subprocess.run(
            ['/usr/bin/ssh-keygen', '-y', '-P', '', '-f', '/proc/self/fd/' + str(private_fd)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            pass_fds=(private_fd,), timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        fail('could not inspect the deployment private key with ssh-keygen')
    if result.returncode:
        fail('private key is invalid or encrypted; an unencrypted dedicated deployment key is required')
    return public_parts(result.stdout)


def publish_public(parent, name, content):
    # O_EXCL means an existing file/link is never truncated, including a race.
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    try:
        with os.fdopen(fd, 'w', encoding='ascii') as stream:
            stream.write(content + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(parent)
    except BaseException:
        # Preserve the newly created file for diagnosis; do not delete or replace
        # an object another process might have changed after our exclusive open.
        raise


def ensure(mode, path):
    if mode not in ('bootstrap', 'key'):
        fail('mode must be bootstrap or key')
    parent, name = open_parent(path, mode == 'bootstrap')
    private_fd = public_fd = None
    try:
        private_fd = checked_file(parent, name, True)
        public_fd = checked_file(parent, name + '.pub', False)
        if private_fd is None:
            if public_fd is not None:
                fail('orphan public key exists; refusing to replace it or generate a conflicting pair')
            if mode == 'key':
                fail('key mode requires an existing private key')
            temp = tempfile.mkdtemp(prefix='.rise-key-', dir='/proc/self/fd/' + str(parent))
            try:
                candidate = temp + '/key'
                result = subprocess.run(
                    ['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', candidate],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    pass_fds=(parent,), timeout=15, check=False)
                if result.returncode:
                    fail('could not generate a deployment key')
                with open(candidate + '.pub', 'rb') as stream:
                    canonical = public_parts(stream.read(16385))[2]
                # link is an exclusive publication: no rename over existing data.
                os.link(candidate, name, dst_dir_fd=parent, follow_symlinks=False)
                published = os.stat(name, dir_fd=parent, follow_symlinks=False)
                try:
                    os.link(candidate + '.pub', name + '.pub', dst_dir_fd=parent, follow_symlinks=False)
                except BaseException:
                    current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    if (current.st_dev, current.st_ino) == (published.st_dev, published.st_ino):
                        os.unlink(name, dir_fd=parent)
                    raise
                os.fsync(parent)
                return canonical
            finally:
                shutil.rmtree(temp)
        derived = derive(private_fd)
        if public_fd is not None:
            public = public_parts(os.read(public_fd, 16385))
            if public[:2] != derived[:2]:
                fail('existing public key does not match private key; files were not changed')
        else:
            publish_public(parent, name + '.pub', derived[2])
        return derived[2]
    finally:
        for fd in (private_fd, public_fd, parent):
            if fd is not None:
                os.close(fd)


def main():
    os.umask(0o077)
    if len(sys.argv) != 3:
        print('usage: ssh-key-policy.py bootstrap|key SSH_KEY', file=sys.stderr)
        return 1
    try:
        print(ensure(sys.argv[1], sys.argv[2]))
        return 0
    except (PolicyError, OSError, subprocess.TimeoutExpired) as error:
        message = str(error) if isinstance(error, PolicyError) else 'unsafe key path, unavailable file, or key creation race; existing files were not overwritten'
        print('SSH key policy: ' + message, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
