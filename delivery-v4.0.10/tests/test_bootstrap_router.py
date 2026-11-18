"""Bootstrap archive route tests (no node or package manager access)."""
import importlib.util
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('route', ROOT / 'lib' / 'bootstrap-route.py')
route = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route)


class BootstrapRouteTests(unittest.TestCase):
    def test_ubuntu_noble_amd64(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'bootstrap-noble-amd64.tar.gz').write_bytes(b'x')
            result = route.route('ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n',
                                 'x86_64', tmp)
        self.assertEqual(result['distro_token'], 'noble')
        self.assertEqual(result['selected'], 'bootstrap-noble-amd64.tar.gz')

    def test_ubuntu_jammy_arm64_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'bootstrap-jammy-arm64.tar.gz').write_bytes(b'x')
            result = route.route('ID=ubuntu\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\n',
                                 'aarch64', tmp)
        self.assertEqual(result['arch_tokens'], ['arm64', 'aarch64'])
        self.assertEqual(result['selected'], 'bootstrap-jammy-arm64.tar.gz')

    def test_kylin_ky10_aarch64(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'bootstrap-ky10-aarch64.tar.gz').write_bytes(b'x')
            result = route.route('ID=kylin\nVERSION_ID="10"\nVERSION_CODENAME=\n',
                                 'aarch64', tmp)
        self.assertEqual(result['distro_token'], 'ky10')
        self.assertEqual(result['selected'], 'bootstrap-ky10-aarch64.tar.gz')

    def test_missing_archive_is_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = route.route('ID=ubuntu\nVERSION_ID="24.04"\n', 'x86_64', tmp)
        self.assertIsNone(result['selected'])
        self.assertEqual(result['candidates'], ['bootstrap-noble-amd64.tar.gz'])


if __name__ == '__main__':
    unittest.main()
