"""Tests for odd Master/Etcd quorum, schema single-source rules, and nerdctl preinstall."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web'))
import config_model  # noqa: E402

NODE = os.environ.get('NODE') or shutil.which('node')


def _make_nodes(master_count, worker_only_count=0, include_registry=True, etcd_mismatch=False):
    nodes = []
    for idx in range(1, master_count + 1):
        roles = ['control_plane', 'worker']
        if not (etcd_mismatch and idx == master_count):
            roles.append('etcd')
        if include_registry and idx == 1:
            roles.append('registry')
        nodes.append({
            'name': f'master{idx}',
            'address': f'192.0.2.{10 + idx}',
            'internal_address': f'192.0.2.{10 + idx}',
            'user': 'root',
            'port': 22,
            'arch': 'amd64',
            'os': 'ubuntu-24.04-debs',
            'roles': roles,
            'connection': 'ssh',
            'data_path': '/data',
            'data_mode': 'existing',
            'device': '',
            'password_env': '',
        })
    for idx in range(1, worker_only_count + 1):
        nodes.append({
            'name': f'worker{idx}',
            'address': f'192.0.2.{50 + idx}',
            'internal_address': f'192.0.2.{50 + idx}',
            'user': 'root',
            'port': 22,
            'arch': 'amd64',
            'os': 'ubuntu-24.04-debs',
            'roles': ['worker'],
            'connection': 'ssh',
            'data_path': '/data',
            'data_mode': 'existing',
            'device': '',
            'password_env': '',
        })
    return nodes


class MasterEtcdOddQuorumAndSchemaTests(unittest.TestCase):
    def test_schema_exposes_install_nerdctl_and_declarative_visible_when(self):
        spec = config_model.schema()
        by_key = {f['key']: f for f in spec['settings']}
        self.assertIn('INSTALL_NERDCTL', by_key)
        self.assertIs(by_key['INSTALL_NERDCTL']['default'], True)
        self.assertEqual(by_key['INSTALL_NERDCTL']['visible_when'],
                         {'field': 'COMPONENTS', 'in': ['all', 'k8s']})
        self.assertEqual(by_key['HARBOR_ADDRESS']['visible_when'],
                         {'field': 'REGISTRY_MODE', 'equals': 'external-harbor'})

    def test_import_accepts_cli_cluster_env_and_byo_ca_fields(self):
        env_text = (
            "CLUSTER_NAME='rise-sec'\n"
            "ZONE='cn'\n"
            "INSTALL_NERDCTL='false'\n"
            "PKI_ROOT_CERT='/etc/rise/root.crt'\n"
            "PKI_ROOT_KEY='/etc/rise/root.key'\n"
            "SSH_KNOWN_HOSTS='/etc/ssh/rise_known_hosts'\n"
            "SSH_KNOWN_HOSTS_SHA256='" + ('a' * 64) + "'\n"
            "NODES='node1|192.0.2.10|192.0.2.10|root|22|amd64|ubuntu-24.04-debs|control_plane,worker,etcd,registry|ssh|/data|existing||'\n"
        )
        cfg = config_model.import_env(env_text)
        self.assertIs(cfg['settings']['INSTALL_NERDCTL'], False)
        self.assertEqual(cfg['settings']['CLUSTER_NAME'], 'rise-sec')
        with self.assertRaises(config_model.ModelError):
            config_model.import_env("PKI_ROOT_CERT='../bad'\nNODES=''\n")

    def test_odd_master_etcd_counts_pass_and_even_or_mismatched_fail(self):
        for odd in (1, 3, 5, 7):
            cfg = config_model.default_config()
            cfg['nodes'] = _make_nodes(odd, worker_only_count=1)
            cfg['settings']['ENDPOINT_TYPE'] = 'local' if odd == 1 else 'kube-vip'
            cfg['settings']['ENDPOINT_ADDRESS'] = '' if odd == 1 else '192.0.2.200'
            config_model.validate_topology(cfg)

        for invalid_count in (0, 2, 4, 6):
            cfg = config_model.default_config()
            cfg['nodes'] = _make_nodes(invalid_count, worker_only_count=1, include_registry=False)
            cfg['nodes'][0]['roles'].append('registry')
            cfg['settings']['ENDPOINT_TYPE'] = 'kube-vip'
            cfg['settings']['ENDPOINT_ADDRESS'] = '192.0.2.200'
            with self.assertRaises(config_model.ModelError):
                config_model.validate_topology(cfg)

        # 5 masters with local endpoint must fail (VIP/external required for >=3)
        cfg_five_local = config_model.default_config()
        cfg_five_local['nodes'] = _make_nodes(5)
        cfg_five_local['settings']['ENDPOINT_TYPE'] = 'local'
        with self.assertRaises(config_model.ModelError):
            config_model.validate_topology(cfg_five_local)

        # Master without co-located etcd or standalone etcd on worker must fail
        cfg_mismatch = config_model.default_config()
        cfg_mismatch['nodes'] = _make_nodes(3, etcd_mismatch=True)
        with self.assertRaises(config_model.ModelError):
            config_model.validate_topology(cfg_mismatch)

        # Pure harbor component allows 0 masters
        cfg_harbor = config_model.default_config()
        cfg_harbor['settings']['COMPONENTS'] = 'harbor'
        cfg_harbor['nodes'] = [{
            'name': 'reg1', 'address': '192.0.2.30', 'internal_address': '192.0.2.30',
            'user': 'root', 'port': 22, 'arch': 'amd64', 'os': 'ubuntu-24.04-debs',
            'roles': ['registry'], 'connection': 'ssh', 'data_path': '/data',
            'data_mode': 'existing', 'device': '', 'password_env': '',
        }]
        config_model.validate_topology(cfg_harbor)

    @unittest.skipUnless(NODE, 'node required for JS pruneConfig round-trip')
    def test_all_example_envs_survive_web_prune_round_trip(self):
        examples = sorted((ROOT / 'examples').glob('*.env')) + [ROOT / 'cluster-vars.env.example']
        script = (
            'const fs=require("fs");'
            'const logic=require("./web/static/workbench-logic.js");'
            'const schema=JSON.parse(fs.readFileSync("./web/schema.json","utf8"));'
            'const cfg=JSON.parse(fs.readFileSync(0,"utf8"));'
            'const out=logic.pruneConfig(cfg, logic.schemaRules(schema), cfg.settings.SSH_AUTH_MODE||"bootstrap");'
            'process.stdout.write(JSON.stringify(out));'
        )
        for env_path in examples:
            imported = config_model.import_env(env_path.read_text(encoding='utf-8'))
            proc = subprocess.run([NODE, '-e', script], input=json.dumps(imported),
                                  cwd=str(ROOT), capture_output=True, text=True, check=True)
            pruned = config_model.normalize_config(json.loads(proc.stdout))
            config_model.validate_topology(pruned)
            exported = config_model.export_env(pruned)
            reimported = config_model.import_env(exported)
            for critical in ('COMPONENTS', 'REGISTRY_MODE', 'HARBOR_ADDRESS', 'HARBOR_DOMAIN',
                             'HARBOR_PORT', 'HARBOR_CA', 'ENDPOINT_TYPE'):
                self.assertEqual(reimported['settings'][critical], imported['settings'][critical],
                                 f'{env_path.name} lost {critical} across Web prune round-trip')

    def test_cli_shell_scripts_enforce_odd_quorum_not_hardcoded_1_or_3(self):
        config_sh = (ROOT / 'lib' / 'config.sh').read_text(encoding='utf-8')
        wizard_nodes = (ROOT / 'lib' / 'wizard-nodes.sh').read_text(encoding='utf-8')
        wizard_sh = (ROOT / 'lib' / 'wizard.sh').read_text(encoding='utf-8')
        self.assertNotIn('in 1|3)', config_sh)
        self.assertIn('% 2', config_sh)
        self.assertIn('-ge 3', wizard_sh)
        self.assertIn('% 2', wizard_nodes)


if __name__ == '__main__':
    unittest.main()
