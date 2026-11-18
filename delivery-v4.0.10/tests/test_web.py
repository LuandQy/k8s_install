"""Regression tests for the Web configuration and execution changes.

Run from the project root:  python3 -m unittest discover -s tests -v
These tests never start the HTTP server, connect to nodes, or run deploy.sh.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web'))

import artifact_digest  # noqa: E402
import config_model  # noqa: E402
import execution  # noqa: E402


class ConfigModelTests(unittest.TestCase):
    def test_vrrp_range_is_enforced(self):
        config = config_model.default_config()
        for value in (1, 31, 255):
            config['settings']['HARBOR_VRRP_ID'] = value
            self.assertEqual(config_model.normalize_config(config)['settings']['HARBOR_VRRP_ID'], value)
        for value in (0, 256, -1):
            config['settings']['HARBOR_VRRP_ID'] = value
            with self.assertRaises(config_model.ModelError):
                config_model.normalize_config(config)

    def test_export_has_no_passwords_by_default(self):
        config = config_model.default_config()
        text = config_model.export_env(config)
        self.assertNotIn('HARBOR_PASSWORD=', text)

    def test_export_credentials_only_when_requested(self):
        config = config_model.default_config()
        config['nodes'][0]['password_env'] = 'NODE1_PASSWORD'
        credentials = {'harbor': 'Abcdef123456', 'node:' + config['nodes'][0]['name']: 'node secret'}
        text = config_model.export_env(config, credentials, True)
        self.assertIn("HARBOR_PASSWORD='Abcdef123456'", text)
        self.assertIn("NODE1_PASSWORD='node secret'", text)
        self.assertNotIn('HARBOR_PASSWORD=', config_model.export_env(config, credentials, False))

    def test_removed_region_pki_and_known_hosts_fields_are_absent(self):
        config = config_model.default_config()
        text = config_model.export_env(config_model.normalize_config(config))
        for key in ('ZONE', 'PKI_ROOT_CERT', 'PKI_ROOT_KEY', 'SSH_KNOWN_HOSTS', 'SSH_KNOWN_HOSTS_SHA256'):
            self.assertNotIn(key, config['settings'])
            self.assertNotIn(key + '=', text)
            self.assertNotIn(key, {field['key'] for field in config_model.schema()['settings']})

    def test_export_rejects_unknown_credential_keys(self):
        config = config_model.default_config()
        with self.assertRaises(config_model.ModelError):
            config_model.export_env(config, {'node:unknown': 'x'}, True)

    def test_import_still_rejects_password_values(self):
        with self.assertRaises(config_model.ModelError):
            config_model.import_env("HARBOR_PASSWORD='secret'\nNODES=''\n")


class JobLogTests(unittest.TestCase):
    def test_logs_are_not_redacted(self):
        log = execution.JobLog()
        output = log.feed(b'password=supersecret token: abc\n')
        self.assertEqual(output, b'password=supersecret token: abc\n')

    def test_control_and_escape_bytes_are_removed(self):
        log = execution.JobLog()
        output = log.feed(b'\x1b[31mred\x1b[0m\x00\r\n')
        self.assertEqual(output, b'red\n')

    def test_c1_and_bidi_controls_are_removed(self):
        log = execution.JobLog()
        output = log.feed('a\u009b b\u202e c\u2066\tend\n'.encode('utf-8'))
        self.assertEqual(output.decode('utf-8'), 'a b c\tend\n')

    def test_overlong_line_is_dropped_in_one_piece(self):
        log = execution.JobLog()
        log.max_line = 16
        output = log.feed(b'x' * 40 + b'\n')
        self.assertEqual(output.decode('utf-8'), '[超长日志行已丢弃]\n')

    def test_submitted_secrets_are_exact_masked_in_job_log(self):
        log = execution.JobLog(secrets=['Harbor@Secret123', 'NodePass#99'])
        output = log.feed(b'login -p Harbor@Secret123 sshpass NodePass#99 keep=plain\n')
        text = output.decode('utf-8')
        self.assertNotIn('Harbor@Secret123', text)
        self.assertNotIn('NodePass#99', text)
        self.assertIn('login -p [REDACTED] sshpass [REDACTED] keep=plain', text)


def plan_result():
    return {'valid': True, 'schema_version': 1, 'kind': 'plan',
            'execution_authorized': False, 'live_checks_performed': False,
            'steps': ['access', 'prepare', 'deps', 'services-init', 'services-verify',
                      'harbor-install', 'harbor-projects', 'images-import', 'images-verify',
                      'k8s-install', 'node-images-verify', 'cluster-verify', 'ledger'],
            'blockers': [], 'checks_not_performed': []}


class FakeCLI:
    def run(self, operation, config):
        return plan_result()


def make_service(tmp):
    project = Path(tmp) / 'project'
    (project / 'artifact').mkdir(parents=True)
    (project / 'deploy.sh').write_text('#!/usr/bin/env bash\n', encoding='utf-8')
    (project / 'artifact' / 'kubekey-artifact.tgz').write_bytes(b'not a real archive')
    service = execution.ExecutionService(
        project_root=str(project), data_dir=str(Path(tmp) / 'executor-data'),
        work_root=str(Path(tmp) / 'executor-work'),
        allowed_uid=os.getuid(), preview_cli=FakeCLI(), runner=lambda *a: 0, trusted_uid=os.getuid())
    return service, project


class ArtifactDigestTests(unittest.TestCase):
    def test_sidecar_manifest_and_explicit_priority(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            artifact = project / 'artifact' / 'kubekey-artifact.tgz'
            artifact.parent.mkdir()
            artifact.write_bytes(b'x')
            sidecar = Path(str(artifact) + '.sha256')
            sidecar.write_text('b' * 64 + '  kubekey-artifact.tgz\n', encoding='utf-8')
            self.assertEqual(artifact_digest.resolve(project, str(artifact)), 'b' * 64)
            sidecar.unlink()
            (project / 'artifact' / 'SHA256SUMS').write_text('c' * 64 + '  kubekey-artifact.tgz\n', encoding='utf-8')
            self.assertEqual(artifact_digest.resolve(project, str(artifact)), 'c' * 64)
            self.assertEqual(artifact_digest.resolve(project, str(artifact), 'd' * 64), 'd' * 64)
            self.assertEqual(artifact_digest.resolve(project, str(project / '..' / 'outside')), '')


class ExecutionPreviewTests(unittest.TestCase):
    def setUp(self):
        # The workspace is private to this user, so the execution service can
        # treat it as a protected root without touching the real project.
        base = ROOT / '.test-tmp'
        base.mkdir(mode=0o700, exist_ok=True)
        self.tmp = tempfile.mkdtemp(prefix='rise-web-test-', dir=str(base))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def config(self, project):
        config = config_model.default_config()
        settings = config['settings']
        settings['CLUSTER_NAME'] = 'test-cluster'
        settings['ARTIFACT_FILE'] = str(project / 'artifact' / 'kubekey-artifact.tgz')
        settings['ARTIFACT_SHA256'] = 'a' * 64
        settings['DEPS_MODE'] = 'iso'
        settings['STATE_DIR'] = ''
        node = config['nodes'][0]
        node['name'] = 'node1'
        node['address'] = '192.0.2.10'
        node['internal_address'] = '192.0.2.10'
        node['connection'] = 'local'
        node['data_mode'] = 'native'
        node['password_env'] = ''
        return config

    def test_stage_preview_credentials_are_scoped(self):
        service, project = make_service(self.tmp)
        try:
            config = self.config(project)
            prepare = service.preview(config, 'prepare')
            self.assertEqual(prepare['stage'], 'prepare')
            self.assertNotIn('harbor', [item['key'] for item in prepare['required_credentials']])
            harbor = service.preview(config, 'harbor')
            self.assertEqual(harbor['stage'], 'harbor')
            self.assertIn('harbor', [item['key'] for item in harbor['required_credentials']])
            with self.assertRaises(execution.ExecutionError):
                service.preview(config, 'unknown')
        finally:
            service.close()

    def test_prepare_submit_keeps_requested_stage_and_skips_harbor_requirement(self):
        service, project = make_service(self.tmp)
        try:
            config = self.config(project)
            plan = service.preview(config, 'prepare')
            body = {'request_id': str(uuid.uuid4()), 'plan_id': plan['plan_id'],
                    'config_sha256': plan['config_sha256'], 'acknowledged': True,
                    'credentials': {}, 'debug': False, 'stage': 'prepare'}
            job = service.submit(body)
            self.assertEqual(job['stage'], 'prepare')
            self.assertEqual(job['operation'], 'prepare')
        finally:
            service.close()

    def test_effective_auto_fills_artifact_sha_from_sidecar_or_manifest(self):
        service, project = make_service(self.tmp)
        try:
            artifact = project / 'artifact' / 'kubekey-artifact.tgz'
            config = self.config(project)
            config['settings']['ARTIFACT_SHA256'] = ''
            (project / 'artifact' / 'SHA256SUMS').write_text(
                'c' * 64 + '  ./kubekey-artifact.tgz\n', encoding='utf-8')
            effective = service._effective(config)
            self.assertEqual(effective['settings']['ARTIFACT_SHA256'], 'c' * 64)
            sidecar = Path(str(artifact) + '.sha256')
            sidecar.write_text('d' * 64 + '\n', encoding='utf-8')
            effective = service._effective(config)
            self.assertEqual(effective['settings']['ARTIFACT_SHA256'], 'd' * 64)
        finally:
            service.close()

    def test_preview_returns_actions_changes_and_checkbox_acknowledgement(self):
        service, project = make_service(self.tmp)
        try:
            preview = service.preview(self.config(project))
        finally:
            service.close()
        self.assertNotIn('confirmation', preview)
        self.assertEqual(preview['acknowledgement']['required'], True)
        self.assertTrue(preview['acknowledgement']['label'])
        self.assertTrue(any('deploy.sh all' in item for item in preview['actions']))
        self.assertTrue(any(item['key'] == 'CLUSTER_NAME' for item in preview['changes']))
        self.assertTrue(any('STATE_DIR' in item for item in preview['actions']))

    def test_submit_requires_acknowledgement(self):
        service, project = make_service(self.tmp)
        try:
            with self.assertRaises(execution.ExecutionError) as caught:
                service.submit({'request_id': str(uuid.uuid4()), 'plan_id': 'missing',
                                'config_sha256': 'b' * 64, 'acknowledged': False,
                                'credentials': {}, 'debug': False})
            self.assertEqual(caught.exception.code, 'acknowledgement_required')
        finally:
            service.close()

    def test_submit_with_acknowledgement_runs_fake_cli_and_keeps_debug(self):
        service, project = make_service(self.tmp)
        try:
            preview = service.preview(self.config(project))
            job = service.submit({
                'request_id': str(uuid.uuid4()),
                'plan_id': preview['plan_id'],
                'config_sha256': preview['config_sha256'],
                'acknowledged': True,
                'credentials': {'harbor': 'Abcdef123456'},
                'debug': True,
            })
            for thread in service.threads.values():
                thread.join(timeout=10)
            self.assertEqual(job['debug'], True)
            self.assertEqual(service.jobs[job['id']]['state'], 'succeeded')
            self.assertTrue(Path(job['config_path']).is_file())
            self.assertNotIn('HARBOR_PASSWORD', Path(job['config_path']).read_text(encoding='utf-8'))
        finally:
            service.close()

    def test_ssh_password_mode_requires_node_credentials(self):
        service, project = make_service(self.tmp)
        try:
            config = self.config(project)
            node = config['nodes'][0]
            node['connection'] = 'ssh'
            node['user'] = 'root'
            node['port'] = 22
            node['password_env'] = 'NODE1_PASSWORD'
            config['settings']['SSH_AUTH_MODE'] = 'password'
            preview = service.preview(config)
            specs = {item['key']: item for item in preview['required_credentials']}
            self.assertTrue(specs['node:node1']['required'])
            with self.assertRaises(execution.ExecutionError) as caught:
                service.submit({
                    'request_id': str(uuid.uuid4()),
                    'plan_id': preview['plan_id'],
                    'config_sha256': preview['config_sha256'],
                    'acknowledged': True,
                    'credentials': {'harbor': 'Abcdef123456'},
                    'debug': False,
                })
            self.assertEqual(caught.exception.code, 'missing_credentials')
        finally:
            service.close()

    def test_local_node_environment_has_sbin_tools(self):
        service, _project = make_service(self.tmp)
        try:
            plan = {'required_credentials': [{'key': 'harbor', 'required': True}],
                    'effective_config': {'nodes': [{'name': 'node1', 'connection': 'local', 'password_env': ''}]}}
            env = service._environment(plan, {'harbor': 'Abcdef123456'})
        finally:
            service.close()
        parts = env['PATH'].split(':')
        self.assertIn('/usr/sbin', parts)
        self.assertIn('/sbin', parts)

    def test_ha_harbor_preview_is_read_only(self):
        service, project = make_service(self.tmp)
        try:
            config = self.config(project)
            config['settings']['REGISTRY_MODE'] = 'ha-harbor'
            config['settings']['HARBOR_VIP'] = '192.0.2.200'
            config['settings']['HARBOR_VRRP_ID'] = 42
            preview = service.preview(config)
            self.assertTrue(any('HA Harbor' in item for item in preview['warnings']))
            with self.assertRaises(execution.ExecutionError) as caught:
                service.submit({'request_id': str(uuid.uuid4()), 'plan_id': preview['plan_id'],
                                'config_sha256': preview['config_sha256'], 'acknowledged': True,
                                'credentials': {'harbor': 'Abcdef123456'}, 'debug': False})
            self.assertEqual(caught.exception.code, 'unsupported_ha')
        finally:
            service.close()

    def test_artifact_sha256_streams_only_project_file(self):
        service, project = make_service(self.tmp)
        try:
            artifact = project / 'artifact' / 'kubekey-artifact.tgz'
            artifact.write_bytes(b'artifact-bytes')
            outside = Path(self.tmp) / 'outside.tgz'
            outside.write_bytes(b'outside')
            import hashlib
            result = service.artifact_sha256(str(artifact))
            self.assertEqual(result['sha256'], hashlib.sha256(b'artifact-bytes').hexdigest())
            self.assertEqual(result['bytes'], len(b'artifact-bytes'))
            with self.assertRaises(execution.ExecutionError) as caught:
                service.artifact_sha256(str(outside))
            self.assertEqual(caught.exception.code, 'artifact_outside_project')
            with self.assertRaises(execution.ExecutionError) as caught:
                service.artifact_sha256(str(project / '..' / 'outside.tgz'))
            self.assertEqual(caught.exception.code, 'invalid_path')
        finally:
            service.close()

    def test_capabilities_advertise_acknowledgement_and_log_levels(self):
        service, _project = make_service(self.tmp)
        try:
            capabilities = service.capabilities()
        finally:
            service.close()
        self.assertEqual(capabilities['confirmation'], 'acknowledgement')
        self.assertEqual(capabilities['log_levels'], ['info', 'debug'])

    def test_staged_continuation_guards_config_drift_and_completed_cluster(self):
        service, project = make_service(self.tmp)
        try:
            config = self.config(project)
            prep = service.preview(config, 'prepare')
            j1 = service.submit({
                'request_id': str(uuid.uuid4()), 'plan_id': prep['plan_id'],
                'config_sha256': prep['config_sha256'], 'acknowledged': True,
                'credentials': {}, 'debug': False, 'stage': 'prepare',
            })
            service.threads[j1['id']].join(timeout=10)
            self.assertEqual(service.jobs[j1['id']]['state'], 'succeeded')

            # Mutated config for the same cluster_name must be rejected
            mutated = self.config(project)
            mutated['settings']['K8S_DOMAIN'] = 'drifted.rise.io'
            harbor_drifted = service.preview(mutated, 'harbor')
            with self.assertRaises(execution.ExecutionError) as drift_err:
                service.submit({
                    'request_id': str(uuid.uuid4()), 'plan_id': harbor_drifted['plan_id'],
                    'config_sha256': harbor_drifted['config_sha256'], 'acknowledged': True,
                    'credentials': {'harbor': 'Abcdef123456'}, 'debug': False, 'stage': 'harbor',
                })
            self.assertIn(drift_err.exception.code, ('config_changed_between_stages', 'cluster_claimed'))

            # Unchanged config progresses cleanly through harbor -> k8s
            harbor_ok = service.preview(config, 'harbor')
            j2 = service.submit({
                'request_id': str(uuid.uuid4()), 'plan_id': harbor_ok['plan_id'],
                'config_sha256': harbor_ok['config_sha256'], 'acknowledged': True,
                'credentials': {'harbor': 'Abcdef123456'}, 'debug': False, 'stage': 'harbor',
            })
            service.threads[j2['id']].join(timeout=10)
            self.assertEqual(service.jobs[j2['id']]['state'], 'succeeded')

            k8s_ok = service.preview(config, 'k8s')
            j3 = service.submit({
                'request_id': str(uuid.uuid4()), 'plan_id': k8s_ok['plan_id'],
                'config_sha256': k8s_ok['config_sha256'], 'acknowledged': True,
                'credentials': {'harbor': 'Abcdef123456'}, 'debug': False, 'stage': 'k8s',
            })
            service.threads[j3['id']].join(timeout=10)
            self.assertEqual(service.jobs[j3['id']]['state'], 'succeeded')

            # Once k8s stage succeeded, re-running fresh-install stages on the same cluster is rejected
            replay = service.preview(config, 'prepare')
            with self.assertRaises(execution.ExecutionError) as replay_err:
                service.submit({
                    'request_id': str(uuid.uuid4()), 'plan_id': replay['plan_id'],
                    'config_sha256': replay['config_sha256'], 'acknowledged': True,
                    'credentials': {}, 'debug': False, 'stage': 'prepare',
                })
            self.assertEqual(replay_err.exception.code, 'cluster_claimed')
        finally:
            service.close()

    def test_execution_masks_submitted_credentials_and_retains_head_and_tail_over_max_log(self):
        def noisy_runner(job, env, emit):
            emit(('HEAD-START secret=%s\n' % env.get('HARBOR_PASSWORD', '')).encode('utf-8'))
            chunk = ('middle-padding-' + ('m' * 1000) + '\n').encode('utf-8')
            for _ in range(5200):
                emit(chunk)
            emit(b'TAIL-FINAL-ERROR: kubeadm join timeout\n')
            return 1

        project = Path(self.tmp) / 'project'
        (project / 'artifact').mkdir(parents=True)
        (project / 'deploy.sh').write_text('#!/usr/bin/env bash\n', encoding='utf-8')
        (project / 'artifact' / 'kubekey-artifact.tgz').write_bytes(b'archive')
        service = execution.ExecutionService(
            project_root=str(project), data_dir=str(Path(self.tmp) / 'executor-data'),
            work_root=str(Path(self.tmp) / 'executor-work'), allowed_uid=os.getuid(),
            preview_cli=FakeCLI(), runner=noisy_runner, trusted_uid=os.getuid())
        try:
            config = self.config(project)
            preview = service.preview(config)
            job = service.submit({
                'request_id': str(uuid.uuid4()), 'plan_id': preview['plan_id'],
                'config_sha256': preview['config_sha256'], 'acknowledged': True,
                'credentials': {'harbor': 'SuperSecretHarbor123'}, 'debug': True,
            })
            service.threads[job['id']].join(timeout=15)
            log_file = service.jobs_dir / job['id'] / 'output.log'
            self.assertLessEqual(log_file.stat().st_size, execution.MAX_LOG)
            full_text = []
            offset = 0
            while True:
                page = service.logs(job['id'], offset)
                full_text.append(page['text'])
                if page['next_offset'] == offset:
                    break
                offset = page['next_offset']
            joined = ''.join(full_text)
            self.assertIn('HEAD-START secret=[REDACTED]', joined)
            self.assertNotIn('SuperSecretHarbor123', joined)
            self.assertIn('TAIL-FINAL-ERROR: kubeadm join timeout', joined)
            self.assertIn('省略', joined)
        finally:
            service.close()


if __name__ == '__main__':
    unittest.main()
