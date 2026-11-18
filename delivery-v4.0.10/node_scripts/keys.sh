#!/usr/bin/env bash
set -euo pipefail
# --check is read-only and runs on all targets before any public-key write.
# A private key is never copied to nodes. Python/OpenSSH must already be present.
command -v python3 >/dev/null || { printf 'SSH key policy: Python 3 is required before key distribution\n' >&2; exit 1; }
python3 - "$@" <<'PY'
import base64
import fcntl
import os
import re
import shlex
import stat
import subprocess
import sys


class PolicyError(Exception):
    pass


def fail(message):
    raise PolicyError(message)


def blob(value):
    try:
        return base64.b64decode(value + '=' * ((-len(value)) % 4), validate=True)
    except (ValueError, UnicodeError):
        return None


def inspect(info, directory=False):
    if (not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022
            or not directory and info.st_nlink != 1):
        fail('SSH directory/key file has unsafe type, ownership, permissions or links')
    if not directory and info.st_size > 1024 * 1024:
        fail('authorized_keys exceeds 1 MiB; review manually')


def can_create(directory):
    if (stat.S_IMODE(os.fstat(directory).st_mode) & 0o300 != 0o300
            or not os.access('.', os.W_OK | os.X_OK, dir_fd=directory, effective_ids=True)):
        fail('directory is not writable for key creation; permissions were not changed')


def existing_match(content, key_type, key_blob, encoded):
    found = False
    try:
        text = content.decode('utf-8')
    except UnicodeError:
        fail('authorized_keys is not valid UTF-8; review manually')
    if re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', text):
        fail('authorized_keys contains control characters; review manually')
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        try:
            # Read only the options/key/blob prefix. Comments are free text and
            # may contain unmatched quotes (e.g. Bob's laptop), not shell input.
            lexer = shlex.shlex(line, posix=True)
            lexer.whitespace_split = True
            lexer.commenters = ''
            first, second = lexer.get_token(), lexer.get_token()
            if blob(second or '') == key_blob:
                if first != key_type or not re.match(re.escape(key_type) + r'[ \t]+', line.lstrip()):
                    fail('ambiguous key type in authorized_keys; review manually')
                found = True
                continue
            if first and first.startswith(('ssh-', 'ecdsa-', 'sk-')):
                # A different unrestricted key; its trailing comment is ignored.
                continue
            third = lexer.get_token()
            if blob(third or '') == key_blob:
                if second != key_type:
                    fail('ambiguous key type in authorized_keys; review manually')
                fail('restricted authorized_keys entry exists for this key; refusing to broaden its permissions')
        except ValueError:
            if encoded in line:
                fail('ambiguous existing entry for this public key; refusing unrestricted append')
            continue
        if encoded in line:
            fail('ambiguous existing entry for this public key; review manually')
    return found


def main():
    args = sys.argv[1:]
    check = len(args) == 2 and args[0] == '--check'
    if not (check or len(args) == 1):
        fail('usage: keys.sh [--check] PUBLIC_KEY')
    public = args[-1]
    if '\n' in public or '\r' in public or len(public) > 16384:
        fail('one public key is required')
    parts = public.split()
    if (len(parts) < 2 or not re.fullmatch(r'ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)', parts[0])
            or not blob(parts[1])):
        fail('public key format is unsupported')
    canonical = parts[0] + ' ' + base64.b64encode(blob(parts[1])).decode('ascii')
    result = subprocess.run(['/usr/bin/ssh-keygen', '-l', '-f', '/dev/stdin'],
                            input=(canonical + '\n').encode('ascii'), stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=10, check=False)
    if result.returncode:
        fail('public key is invalid')
    home_fd = os.open(os.environ['HOME'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    directory = key_fd = None
    try:
        home_info = os.fstat(home_fd)
        if home_info.st_uid != os.getuid() or stat.S_IMODE(home_info.st_mode) & 0o022:
            fail('home directory ownership or permissions are unsafe')
        try:
            directory = os.open('.ssh', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=home_fd)
        except FileNotFoundError:
            can_create(home_fd)
            if check:
                print('SSH key policy: no existing authorized_keys conflict')
                return
            os.mkdir('.ssh', 0o700, dir_fd=home_fd)
            directory = os.open('.ssh', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=home_fd)
        inspect(os.fstat(directory), directory=True)
        fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            key_fd = os.open('authorized_keys', (os.O_RDONLY if check else os.O_RDWR | os.O_APPEND)
                             | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            can_create(directory)
            if check:
                print('SSH key policy: no existing authorized_keys conflict')
                return
            key_fd = os.open('authorized_keys', os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
            content = b''
            after = os.fstat(key_fd)
        else:
            inspect(os.fstat(key_fd))
            before = os.fstat(key_fd)
            content = os.read(key_fd, 1024 * 1024 + 1)
            if len(content) > 1024 * 1024:
                fail('authorized_keys grew past the size limit; review manually')
            after = os.fstat(key_fd)
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                fail('authorized_keys changed while being checked; review manually')
        found = existing_match(content, parts[0], blob(parts[1]), parts[1])
        if not found and (not stat.S_IMODE(os.fstat(key_fd).st_mode) & 0o200
                          or not os.access('authorized_keys', os.W_OK, dir_fd=directory, effective_ids=True)):
            fail('authorized_keys is read-only; permissions were not changed')
        if check or found:
            print('SSH key policy: already authorized' if found else 'SSH key policy: safe to append')
            return
        descriptor = os.fstat(key_fd)
        current = os.stat('authorized_keys', dir_fd=directory, follow_symlinks=False)
        if (descriptor.st_dev, descriptor.st_ino) != (current.st_dev, current.st_ino):
            fail('authorized_keys was replaced while being checked; refusing append')
        if (descriptor.st_size, descriptor.st_mtime_ns, descriptor.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            fail('authorized_keys changed before append; review manually')
        addition = (b'\n' if content and not content.endswith(b'\n') else b'') + (canonical + '\n').encode('ascii')
        if os.write(key_fd, addition) != len(addition):
            fail('incomplete append; retain the file and review manually')
        os.fsync(key_fd); os.fsync(directory)
        print('SSH key policy: public key appended; existing entries preserved')
    finally:
        for fd in (key_fd, directory, home_fd):
            if fd is not None:
                os.close(fd)


os.umask(0o077)
try:
    main()
except (PolicyError, OSError, KeyError, subprocess.TimeoutExpired) as error:
    message = str(error) if isinstance(error, PolicyError) else 'unsafe or unavailable key path; no existing entry was replaced'
    print('SSH key policy: ' + message, file=sys.stderr)
    sys.exit(1)
PY
