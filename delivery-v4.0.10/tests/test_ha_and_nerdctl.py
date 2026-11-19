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
        examples = [
            p for p in sorted((ROOT / 'examples').glob('*.env'))
            if not p.name.startswith('workers-')
        ] + [ROOT / 'cluster-vars.env.example']
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


class NerdctlPreinstallTests(unittest.TestCase):
    def test_nerdctl_node_script_extracts_amd64_and_arm64_and_writes_toml(self):
        script = ROOT / 'node_scripts' / 'nerdctl.sh'
        self.assertTrue(script.is_file(), 'missing node_scripts/nerdctl.sh')
        cases = [
            ('amd64', 'x86_64', 62),
            ('arm64', 'aarch64', 183),
        ]
        import struct
        import tempfile
        for arch, uname_m, elf_machine in cases:
            archive = ROOT / 'artifact' / 'tools' / arch / f'nerdctl-2.2.1-linux-{arch}.tar.gz'
            self.assertTrue(archive.is_file(), f'missing bundled archive {archive}')
            with tempfile.TemporaryDirectory() as tmp:
                env = dict(os.environ, NERDCTL_DEST_ROOT=tmp, NERDCTL_TEST_UNAME_M=uname_m)
                res = subprocess.run(['/bin/sh', str(script), str(archive), arch],
                                     env=env, capture_output=True, text=True)
                self.assertEqual(res.returncode, 0, res.stderr)
                binary = Path(tmp) / 'usr' / 'local' / 'bin' / 'nerdctl'
                toml = Path(tmp) / 'etc' / 'nerdctl' / 'nerdctl.toml'
                self.assertTrue(binary.is_file())
                self.assertTrue(os.access(binary, os.X_OK))
                header = binary.read_bytes()[:20]
                self.assertEqual(header[:4], b'\x7fELF')
                machine = struct.unpack('<H', header[18:20])[0]
                self.assertEqual(machine, elf_machine)
                toml_text = toml.read_text(encoding='utf-8')
                self.assertIn('namespace      = "k8s.io"', toml_text)
                self.assertIn('cgroup_manager = "cgroupfs"', toml_text)
                self.assertIn('/etc/containerd/certs.d', toml_text)

                # Idempotency: custom marker in existing nerdctl.toml is preserved on re-run
                toml.write_text(toml_text + '# keep-custom\n', encoding='utf-8')
                res2 = subprocess.run(['/bin/sh', str(script), '/nonexistent/ignored-when-present.tgz', arch],
                                      env=env, capture_output=True, text=True)
                self.assertEqual(res2.returncode, 0, res2.stderr)
                self.assertIn('# keep-custom', toml.read_text(encoding='utf-8'))

                # Missing nerdctl.toml is backfilled even when binary already exists
                toml.unlink()
                res3 = subprocess.run(['/bin/sh', str(script), '/nonexistent/ignored-when-present.tgz', arch],
                                      env=env, capture_output=True, text=True)
                self.assertEqual(res3.returncode, 0, res3.stderr)
                self.assertTrue(toml.is_file())

    def test_nerdctl_node_script_rejects_arch_mismatch(self):
        script = ROOT / 'node_scripts' / 'nerdctl.sh'
        self.assertTrue(script.is_file())
        archive = ROOT / 'artifact' / 'tools' / 'amd64' / 'nerdctl-2.2.1-linux-amd64.tar.gz'
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, NERDCTL_DEST_ROOT=tmp, NERDCTL_TEST_UNAME_M='aarch64')
            res = subprocess.run(['/bin/sh', str(script), str(archive), 'amd64'],
                                 env=env, capture_output=True, text=True)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn('架构不匹配', res.stderr)

    def test_nerdctl_wired_into_init_deps_render_and_kk_verify(self):
        artifact_sh = (ROOT / 'lib' / 'artifact.sh').read_text(encoding='utf-8')
        init_sh = (ROOT / 'init.sh').read_text(encoding='utf-8')
        config_base = (ROOT / 'config-base.yaml').read_text(encoding='utf-8')
        kk_verify = (ROOT / 'kk-project' / 'roles' / 'rise' / 'verify' / 'tasks' / 'main.yaml').read_text(encoding='utf-8')
        self.assertIn('install_k8s_nodes_nerdctl', artifact_sh)
        self.assertIn('node_scripts/nerdctl.sh', artifact_sh)
        self.assertIn('install_k8s_nodes_nerdctl', init_sh)
        self.assertIn('install_nerdctl:', config_base)
        self.assertIn('.rise.install_nerdctl', kk_verify)


class ReceiptAndMaintenanceConvergenceTests(unittest.TestCase):
    def test_byo_ca_paths_persisted_and_restored_across_receipts(self):
        resume_sh = (ROOT / 'lib' / 'resume.sh').read_text(encoding='utf-8')
        prepared_sh = (ROOT / 'lib' / 'prepared-config.sh').read_text(encoding='utf-8')
        redeploy_sh = (ROOT / 'redeploy.sh').read_text(encoding='utf-8')
        expansion_sh = (ROOT / 'lib' / 'expansion.sh').read_text(encoding='utf-8')
        for text, name in ((resume_sh, 'lib/resume.sh'),
                           (prepared_sh, 'lib/prepared-config.sh'),
                           (redeploy_sh, 'redeploy.sh'),
                           (expansion_sh, 'lib/expansion.sh')):
            self.assertIn('PKI_ROOT_CERT', text, f'{name} missing PKI_ROOT_CERT persistence')
            self.assertIn('PKI_ROOT_KEY', text, f'{name} missing PKI_ROOT_KEY persistence')

    def test_expansion_check_receipt_restores_byo_ca_and_rejects_tampered_ca(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            fake_root = tpath / 'fake_root'
            (fake_root / 'kk-project').mkdir(parents=True)
            (fake_root / 'kk-project' / 'stub.yaml').write_text('stub: true\n', encoding='utf-8')
            work_dir = tpath / 'work'
            (work_dir / 'pki').mkdir(parents=True)
            (work_dir / 'pki' / 'root.crt').write_text('ROOT-CA-BODY\n', encoding='utf-8')
            byo_cert = tpath / 'byo-root.crt'
            byo_key = tpath / 'byo-root.key'
            byo_cert.write_text('BYO-CERT-V1\n', encoding='utf-8')
            byo_key.write_text('BYO-KEY-V1\n', encoding='utf-8')

            state_dir = tpath / 'state' / 'rise'
            receipt = tpath / 'state' / 'rise.deployment'
            run_dir = tpath / 'run'
            state_dir.mkdir(parents=True)
            receipt.mkdir(parents=True)
            run_dir.mkdir(parents=True)

            (state_dir / 'cluster.env').write_text('CLUSTER_NAME=rise\n', encoding='utf-8')
            (receipt / 'cluster.env').write_text('CLUSTER_NAME=rise\n', encoding='utf-8')
            (receipt / 'id').write_text('dep-test-001\n', encoding='utf-8')
            (receipt / 'status').write_text('complete\n', encoding='utf-8')
            (receipt / 'inventory.yaml').write_text('hosts: []\n', encoding='utf-8')
            (receipt / 'identity.json').write_text('[]\n', encoding='utf-8')
            (receipt / 'PKI_ROOT_CERT.path').write_text(f'{byo_cert}\n', encoding='utf-8')
            (receipt / 'PKI_ROOT_KEY.path').write_text(f'{byo_key}\n', encoding='utf-8')

            prep_script = f'''
set -euo pipefail
die() {{ printf '[ERROR] %s\\n' "$*" >&2; exit 1; }}
sha256_file() {{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{{print $1}}'
    else
        shasum -a 256 "$1" | awk '{{print $1}}'
    fi
}}
. "{ROOT}/lib/resume.sh"
ROOT="{fake_root}"
WORK_DIR="{work_dir}"
PKI_ROOT_CERT="{byo_cert}"
PKI_ROOT_KEY="{byo_key}"
resume_project_digest > "{receipt}/project.sha256"
resume_pki > "{receipt}/pki.sha256"
'''
            prep = subprocess.run(['/bin/bash', '-c', prep_script], capture_output=True, text=True)
            self.assertEqual(prep.returncode, 0, prep.stderr)

            check_script = f'''
set -euo pipefail
die() {{ printf '[ERROR] %s\\n' "$*" >&2; exit 1; }}
sha256_file() {{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{{print $1}}'
    else
        shasum -a 256 "$1" | awk '{{print $1}}'
    fi
}}
. "{ROOT}/lib/resume.sh"
. "{ROOT}/lib/expansion.sh"
ROOT="{fake_root}"
WORK_DIR="{work_dir}"
STATE_DIR="{state_dir}"
RUN_DIR="{run_dir}"
unset HARBOR_CA HARBOR_CERT HARBOR_KEY PKI_ROOT_CERT PKI_ROOT_KEY || true
expansion_check_receipt
printf 'CERT=%s\\nKEY=%s\\n' "${{PKI_ROOT_CERT:-}}" "${{PKI_ROOT_KEY:-}}"
'''
            ok_res = subprocess.run(['/bin/bash', '-c', check_script], capture_output=True, text=True)
            self.assertEqual(ok_res.returncode, 0, ok_res.stderr)
            self.assertIn(f'CERT={byo_cert}', ok_res.stdout)
            self.assertIn(f'KEY={byo_key}', ok_res.stdout)

            # Tamper BYO root certificate and ensure expansion_check_receipt rejects it
            byo_cert.write_text('BYO-CERT-TAMPERED\n', encoding='utf-8')
            bad_res = subprocess.run(['/bin/bash', '-c', check_script], capture_output=True, text=True)
            self.assertNotEqual(bad_res.returncode, 0)
            self.assertIn('原证书或私钥变化', bad_res.stderr)

    def test_workers_new_example_and_external_harbor_expansion_guards(self):
        workers_env = ROOT / 'examples' / 'workers-new.env'
        self.assertTrue(workers_env.is_file(), 'missing examples/workers-new.env')
        parsed = subprocess.run(
            ['/bin/bash', '-eu', '-c', '. "$1"; printf "%s\\n" "${NEW_NODES:?}"', 'bash', str(workers_env)],
            capture_output=True, text=True, check=True,
        )
        rows = [line for line in parsed.stdout.splitlines() if line.strip()]
        self.assertGreater(len(rows), 0)
        for row in rows:
            cols = row.split('|')
            self.assertEqual(len(cols), 13, f'expected 13 columns in {row!r}')
            self.assertEqual(cols[7], 'worker', f'expected worker role in {row!r}')

        scale_sh = (ROOT / 'scale-worker.sh').read_text(encoding='utf-8')
        self.assertIn('[ "${COMPONENTS:-all}" = k8s ] || validate_password', scale_sh)

        add_workers_yaml = (ROOT / 'kk-project' / 'playbooks' / 'add_workers.yaml').read_text(encoding='utf-8')
        self.assertIn('.groups.image_registry | empty | not', add_workers_yaml)
        self.assertIn('.image_registry.type | empty | not', add_workers_yaml)
        self.assertIn('.rise.import_images | default true', add_workers_yaml)

    def test_workflow_status_fix_and_post_maintenance_verify_convergence(self):
        workflow_sh = (ROOT / 'lib' / 'workflow.sh').read_text(encoding='utf-8')
        self.assertNotIn('access.status', workflow_sh)
        self.assertIn('workflow_status access', workflow_sh)
        post_verify = ROOT / 'lib' / 'post-verify.sh'
        self.assertTrue(post_verify.is_file(), 'missing lib/post-verify.sh')
        pv_text = post_verify.read_text(encoding='utf-8')
        self.assertIn('workflow_sync_and_post_verify', pv_text)
        deploy_sh = (ROOT / 'deploy.sh').read_text(encoding='utf-8')
        scale_sh = (ROOT / 'scale-worker.sh').read_text(encoding='utf-8')
        self.assertIn('workflow_sync_and_post_verify', deploy_sh)
        self.assertIn('workflow_sync_and_post_verify', scale_sh)


class NodeRunParallelTests(unittest.TestCase):
    def test_node_run_parallel_respects_concurrency_and_propagates_failure(self):
        common_sh = (ROOT / 'lib' / 'common.sh').read_text(encoding='utf-8')
        self.assertIn('node_run_parallel()', common_sh)
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            # Extract parse_node and node_run_parallel from common.sh and run under /bin/bash
            harness = f'''
set -euo pipefail
RUN_DIR="{tmp}"
SSH_PARALLEL=3
parse_node() {{
    IFS='|' read -r NODE_NAME NODE_ADDRESS NODE_INTERNAL NODE_USER NODE_PORT NODE_ARCH NODE_OS NODE_ROLES NODE_CONNECTION NODE_DATA NODE_DATA_MODE NODE_DEVICE NODE_PASS_ENV <<< "$1"
}}
'''
            start = common_sh.index('node_run_parallel()')
            # Extract function body
            brace_depth = 0
            end = start
            for idx in range(start, len(common_sh)):
                if common_sh[idx] == '{{'[0]:
                    brace_depth += 1
                elif common_sh[idx] == '}}'[0]:
                    brace_depth -= 1
                    if brace_depth == 0:
                        end = idx + 1
                        break
            fn_code = common_sh[start:end]
            rows = '\n'.join(
                f'node{i}|192.0.2.{i}|192.0.2.{i}|root|22|amd64|ubuntu-24.04-debs|worker|ssh|/data|native||'
                for i in range(1, 7)
            )
            ok_script = harness + fn_code + f'''
worker_ok() {{
    printf 'done:%s\\n' "$NODE_NAME"
}}
node_run_parallel worker_ok "{rows}"
'''
            res_ok = subprocess.run(['/bin/bash', '-c', ok_script], capture_output=True, text=True)
            self.assertEqual(res_ok.returncode, 0, res_ok.stderr)
            self.assertEqual(res_ok.stdout.splitlines(), [f'done:node{i}' for i in range(1, 7)])

            fail_script = harness + fn_code + f'''
worker_fail() {{
    if [ "$NODE_NAME" = node4 ]; then
        echo "boom:$NODE_NAME" >&2
        return 7
    fi
    echo "ok:$NODE_NAME"
}}
node_run_parallel worker_fail "{rows}"
'''
            res_fail = subprocess.run(['/bin/bash', '-c', fail_script], capture_output=True, text=True)
            self.assertNotEqual(res_fail.returncode, 0)
            self.assertIn('boom:node4', res_fail.stdout + res_fail.stderr)


class HaproxyEndpointModeTests(unittest.TestCase):
    def test_haproxy_endpoint_type_allows_multi_master_without_vip(self):
        spec = config_model.schema()
        endpoint_field = next(f for f in spec['settings'] if f['key'] == 'ENDPOINT_TYPE')
        self.assertIn('haproxy', endpoint_field['enum'])

        for odd in (3, 5):
            cfg = config_model.default_config()
            cfg['nodes'] = _make_nodes(odd, worker_only_count=2)
            cfg['settings']['ENDPOINT_TYPE'] = 'haproxy'
            cfg['settings']['ENDPOINT_ADDRESS'] = ''
            validated = config_model.validate_topology(cfg)
            self.assertEqual(validated['settings']['ENDPOINT_TYPE'], 'haproxy')

        # Non-empty ENDPOINT_ADDRESS under haproxy must be rejected
        cfg_bad = config_model.default_config()
        cfg_bad['nodes'] = _make_nodes(3, worker_only_count=1)
        cfg_bad['settings']['ENDPOINT_TYPE'] = 'haproxy'
        cfg_bad['settings']['ENDPOINT_ADDRESS'] = '192.0.2.200'
        with self.assertRaises(config_model.ModelError):
            config_model.validate_topology(cfg_bad)

    def test_selected_target_images_includes_haproxy_when_enabled(self):
        script = f'''
set -euo pipefail
ROOT="{ROOT}"
KUBE_VERSION="v1.36.4"
COMPONENTS="all"
ENDPOINT_TYPE="haproxy"
LOCAL_STORAGE="true"
NFS_MODE="none"
. "$ROOT/lib/artifact-requirements.sh"
. "$ROOT/lib/images.sh"
selected_target_images
'''
        res = subprocess.run(['/bin/bash', '-c', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        images = json.loads(res.stdout)
        self.assertIn('docker.io/library/haproxy:2.9.6-alpine', images)
        self.assertNotIn('docker.io/plndr/kube-vip:v0.7.2', images)

    def test_cluster_verify_validate_addresses_supports_multi_master_haproxy_dns_set(self):
        sys.path.insert(0, str(ROOT / 'lib'))
        import cluster_verify  # noqa: E402
        expected = ['192.0.2.11', '192.0.2.12', '192.0.2.13']
        cluster_verify.validate_addresses(['192.0.2.13', '192.0.2.11', '192.0.2.12'], expected)
        with self.assertRaises(RuntimeError):
            cluster_verify.validate_addresses(['192.0.2.11', '192.0.2.99'], expected)
        with self.assertRaises(RuntimeError):
            cluster_verify.validate_addresses(['127.0.0.1'], ['127.0.0.1'])

        worker_ep = (ROOT / 'kk-project' / 'roles' / 'rise' / 'worker-endpoints' / 'tasks' / 'main.yaml').read_text(encoding='utf-8')
        self.assertIn('haproxy', worker_ep)
        self.assertIn('kubekey kubernetes control_plane_endpoint BEGIN', worker_ep)


if __name__ == '__main__':
    unittest.main()
