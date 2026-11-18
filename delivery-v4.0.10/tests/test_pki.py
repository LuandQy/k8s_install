"""BYO root CA staging tests (dev-only; requires Bash 4.4+ and openssl)."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
OPENSSL = shutil.which('openssl')


def bash_supported():
    if not BASH or not OPENSSL:
        return False
    try:
        out = subprocess.run([BASH, '-c', 'printf %s "$BASH_VERSION"'], capture_output=True, text=True, timeout=10)
        parts = out.stdout.split('.')
        return int(parts[0]) > 4 or (int(parts[0]) == 4 and int(parts[1]) >= 4)
    except (OSError, ValueError, IndexError):
        return False


def make_ca(directory, name):
    cert = directory / (name + '.crt')
    key = directory / (name + '.key')
    subprocess.run([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '30',
                    '-subj', '/CN=' + name,
                    '-addext', 'basicConstraints=critical,CA:TRUE',
                    '-addext', 'keyUsage=critical,keyCertSign,cRLSign'],
                   check=True, capture_output=True)
    key.chmod(0o600)
    cert.chmod(0o644)
    return cert, key


def stage(work, cert, key):
    script = '''
set -euo pipefail
cd "$1"
. lib/common.sh
. lib/pki.sh
WORK_DIR="$2"
PKI_ROOT_CERT="$3"
PKI_ROOT_KEY="$4"
pki_stage_root
'''
    return subprocess.run([BASH, '-c', script, 'bash', str(ROOT), str(work), str(cert), str(key)],
                          capture_output=True, text=True, timeout=60)


@unittest.skipUnless(bash_supported(), 'BYO CA tests need Bash 4.4+ and openssl')
class PkiStageTests(unittest.TestCase):
    def setUp(self):
        base = ROOT / '.test-tmp'
        base.mkdir(mode=0o700, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='rise-pki-test-', dir=str(base)))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.work = self.tmp / 'work'
        self.cert, self.key = make_ca(self.tmp, 'root-a')

    def test_stages_validated_root_and_is_idempotent(self):
        first = stage(self.work, self.cert, self.key)
        self.assertEqual(first.returncode, 0, first.stderr)
        target_cert = self.work / 'pki' / 'root.crt'
        target_key = self.work / 'pki' / 'root.key'
        self.assertEqual(target_cert.read_bytes(), self.cert.read_bytes())
        self.assertEqual(target_key.read_bytes(), self.key.read_bytes())
        self.assertEqual(stat.S_IMODE(target_key.stat().st_mode), 0o600)
        second = stage(self.work, self.cert, self.key)
        self.assertEqual(second.returncode, 0, second.stderr)

    def test_rejects_world_readable_key(self):
        self.key.chmod(0o644)
        result = stage(self.work, self.cert, self.key)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('0400 或 0600', result.stderr)

    def test_rejects_different_root_after_install(self):
        self.assertEqual(stage(self.work, self.cert, self.key).returncode, 0)
        other_cert, other_key = make_ca(self.tmp, 'root-b')
        result = stage(self.work, other_cert, other_key)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('不能中途更换根证书', result.stderr)

    def test_rejects_mismatched_pair(self):
        other_cert, _other_key = make_ca(self.tmp, 'root-c')
        result = stage(self.work, other_cert, self.key)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('不匹配', result.stderr)

    def test_render_pins_ca_policy(self):
        env = (ROOT / 'examples' / 'single-master.env').read_text(encoding='utf-8')
        env += '\nPKI_ROOT_CERT=' + str(self.cert) + '\nPKI_ROOT_KEY=' + str(self.key) + '\n'
        envfile = self.tmp / 'site.env'
        envfile.write_text(env, encoding='utf-8')
        output = self.tmp / 'render'
        result = subprocess.run([BASH, str(ROOT / 'deploy.sh'), 'render', '--env', str(envfile),
                                 '--output', str(output)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (output / 'config.yaml').read_text(encoding='utf-8')
        self.assertIn('certs:', text)
        self.assertIn('gen_cert_policy: IfNotPresent', text)

    def test_config_check_requires_both_paths(self):
        env = (ROOT / 'examples' / 'single-master.env').read_text(encoding='utf-8')
        env += '\nPKI_ROOT_CERT=' + str(self.cert) + '\n'
        envfile = self.tmp / 'partial.env'
        envfile.write_text(env, encoding='utf-8')
        result = subprocess.run([BASH, str(ROOT / 'deploy.sh'), 'config-check', '--env', str(envfile), '--json'],
                                capture_output=True, text=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('同时填写', result.stderr)


if __name__ == '__main__':
    unittest.main()
