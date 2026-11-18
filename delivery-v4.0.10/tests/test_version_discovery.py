"""Version discovery behaves as a registry, not a hardcoded menu."""
import importlib.util
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web'))
import config_model  # noqa: E402


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VersionDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rise-versions-')
        self.root = Path(self.tmp.name)
        (self.root / 'configs').mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, version):
        path = self.root / 'configs' / (version + '.yaml')
        path.write_text('spec:\n  kubernetes:\n    kube_version: %s\n' % version, encoding='utf-8')

    def test_new_config_is_discovered_and_sorted(self):
        for version in ('v1.33.9', 'v1.40.1', 'v1.39.2'):
            self.write(version)
        self.assertEqual(config_model.discover_kubernetes_versions(self.root),
                         ['v1.40.1', 'v1.39.2', 'v1.33.9'])
        helper = load('versions', ROOT / 'lib' / 'kubernetes-versions.py')
        self.assertEqual(helper.discover(self.root), ['v1.40.1', 'v1.39.2', 'v1.33.9'])

    def test_mismatched_filename_and_field_is_rejected(self):
        (self.root / 'configs' / 'v1.40.1.yaml').write_text(
            'spec:\n  kubernetes:\n    kube_version: v1.40.2\n', encoding='utf-8')
        with self.assertRaises(ValueError):
            config_model.discover_kubernetes_versions(self.root)
        helper = load('versions2', ROOT / 'lib' / 'kubernetes-versions.py')
        with self.assertRaises(ValueError):
            helper.discover(self.root)

    def test_empty_registry_is_rejected(self):
        with self.assertRaises(ValueError):
            config_model.discover_kubernetes_versions(self.root)


if __name__ == '__main__':
    unittest.main()
