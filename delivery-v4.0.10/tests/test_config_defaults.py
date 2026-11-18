"""Single-source defaults and dynamic version contract tests."""
import json
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web'))
import config_model  # noqa: E402


class ConfigDefaultsTests(unittest.TestCase):
    def test_schema_versions_are_discovered_not_hardcoded(self):
        spec = config_model.schema()
        version = next(field for field in spec['settings'] if field['key'] == 'KUBE_VERSION')
        discovered = config_model.discover_kubernetes_versions()
        self.assertEqual(version['enum'], discovered)
        self.assertEqual(version['default'], discovered[0])
        self.assertEqual(version['version_source'], 'configs/v*.yaml')
        raw = json.loads((ROOT / 'web' / 'schema.json').read_text(encoding='utf-8'))
        raw_version = next(field for field in raw['settings'] if field['key'] == 'KUBE_VERSION')
        self.assertEqual(raw_version['enum'], [])
        self.assertEqual(raw_version['default'], '')

    def test_default_topology_is_ha_and_self_hosted_services(self):
        config = config_model.default_config()
        settings, nodes = config['settings'], config['nodes']
        self.assertEqual(settings['ENDPOINT_TYPE'], 'kube-vip')
        self.assertEqual(settings['CLUSTER_VERIFY_MODE'], 'cross-node')
        self.assertEqual(settings['NTP_MODE'], 'node')
        self.assertEqual(settings['NTP_ALLOW_LOCAL'], True)
        self.assertEqual(settings['NFS_MODE'], 'new')
        self.assertEqual(settings['LOCAL_STORAGE'], True)
        self.assertEqual(settings['REGISTRY_MODE'], 'harbor')
        self.assertEqual(settings['DEPS_MODE'], 'iso')
        self.assertEqual(settings['BOOTSTRAP_ARCHIVE'], '')
        self.assertEqual(len(nodes), 3)
        self.assertEqual(sum('control_plane' in node['roles'] for node in nodes), 3)
        self.assertEqual(sum('registry' in node['roles'] for node in nodes), 1)

    def test_cli_template_uses_same_defaults(self):
        sample = (ROOT / 'cluster-vars.env.example').read_text(encoding='utf-8')
        self.assertIn('NTP_MODE=node', sample)
        self.assertIn('NFS_MODE=new', sample)
        self.assertIn('LOCAL_STORAGE=true', sample)
        wizard = (ROOT / 'lib' / 'wizard.sh').read_text(encoding='utf-8')
        self.assertIn('default_kubernetes_version', wizard)
        common = (ROOT / 'lib' / 'common.sh').read_text(encoding='utf-8')
        self.assertIn('kubernetes-versions.py', common)
        deploy = (ROOT / 'deploy.sh').read_text(encoding='utf-8')
        self.assertIn('--step', deploy)
        self.assertIn('cli', deploy)
        for path in ('lib/config.sh', 'lib/wizard.sh', 'web/server.py', 'web/schema.json'):
            text = (ROOT / path).read_text(encoding='utf-8')
            self.assertNotIn('v1.36.4', text, path)


if __name__ == '__main__':
    unittest.main()
