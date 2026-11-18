"""Offline audit version/architecture discovery tests (pure helpers)."""
import importlib.util
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('offline_audit', ROOT / 'lib' / 'offline-audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class OfflineAuditTests(unittest.TestCase):
    def test_arch_normalization(self):
        self.assertEqual(audit.normalize_arch('x86_64'), 'amd64')
        self.assertEqual(audit.normalize_arch('aarch64'), 'arm64')
        with self.assertRaises(ValueError):
            audit.normalize_arch('mips')

    def test_bootstrap_archives_follow_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'bootstrap').mkdir()
            (root / 'bootstrap' / 'bootstrap-noble-amd64.tar.gz').write_bytes(b'a')
            (root / 'bootstrap' / 'bootstrap-jammy-arm64.tar.gz').write_bytes(b'b')
            (root / 'bootstrap' / 'bootstrap-ky10-aarch64.tar.gz').write_bytes(b'c')
            self.assertEqual([p.name for p in audit.bootstrap_archives(root, 'amd64')],
                             ['bootstrap-noble-amd64.tar.gz'])
            self.assertEqual([p.name for p in audit.bootstrap_archives(root, 'arm64')],
                             ['bootstrap-jammy-arm64.tar.gz', 'bootstrap-ky10-aarch64.tar.gz'])

    def test_iso_members_are_architecture_specific(self):
        names = ['repository/ubuntu-22.04-debs-arm64.iso',
                 'repository/ubuntu-24.04-debs-amd64.iso']
        self.assertEqual(audit.iso_members(names, 'arm64'),
                         ['repository/ubuntu-22.04-debs-arm64.iso'])
        self.assertEqual(audit.iso_members(names, 'amd64'),
                         ['repository/ubuntu-24.04-debs-amd64.iso'])

    def test_kubernetes_versions_reads_configs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'configs').mkdir()
            (root / 'configs' / 'v1.40.1.yaml').write_text(
                'spec:\n  kubernetes:\n    kube_version: v1.40.1\n', encoding='utf-8')
            self.assertEqual(audit.kubernetes_versions(root), ['v1.40.1'])


if __name__ == '__main__':
    unittest.main()
