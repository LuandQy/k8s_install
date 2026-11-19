"""HTTP contract tests for the local workbench (no CLI execution)."""
import base64
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web'))

import config_model  # noqa: E402
import server  # noqa: E402


class HTTPCase(unittest.TestCase):
    def call(self, path, method='GET', body=None):
        data = None if body is None else json.dumps(body).encode('utf-8')
        request = urllib.request.Request('http://127.0.0.1:%d%s' % (self.port, path), data=data, method=method)
        request.add_header('X-Web-Token', self.token)
        if body is not None:
            request.add_header('Content-Type', 'application/json')
            request.add_header('Origin', 'http://127.0.0.1:%d' % self.port)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read().decode('utf-8'))
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read().decode('utf-8'))


class ServerContractTests(HTTPCase):
    @classmethod
    def setUpClass(cls):
        # The draft store must live outside the project tree by design.
        cls.tmp = tempfile.mkdtemp(prefix='rise-web-http-', dir='/tmp')
        cls.token = 'test-token-' + 'x' * 32
        cls.httpd = server.make_server(ROOT, cls.tmp, 0, token=cls.token)
        cls.port = cls.httpd.server_port
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=5)
        shutil.rmtree(cls.tmp, True)

    def test_schema_exposes_credential_metadata_and_vrrp(self):
        status, payload = self.call('/api/schema')
        self.assertEqual(status, 200)
        keys = {field['key'] for field in payload['schema']['settings']}
        self.assertIn('HARBOR_VRRP_ID', keys)
        self.assertEqual(payload['schema']['credentials']['harbor']['required'], True)
        self.assertIn('node', payload['schema']['credentials'])

    def test_export_without_passwords_and_with_explicit_opt_in(self):
        config = config_model.default_config()
        config['nodes'][0]['password_env'] = 'NODE1_PASSWORD'
        name = config['nodes'][0]['name']
        status, payload = self.call('/api/export', 'POST', {'config': config})
        self.assertEqual(status, 200)
        self.assertNotIn('HARBOR_PASSWORD=', payload['text'])
        status, payload = self.call('/api/export', 'POST', {
            'config': config,
            'credentials': {'harbor': 'Abcdef123456', 'node:' + name: 'pw'},
            'include_credentials': True})
        self.assertEqual(status, 200)
        self.assertIn("HARBOR_PASSWORD='Abcdef123456'", payload['text'])
        self.assertIn("NODE1_PASSWORD='pw'", payload['text'])

    def test_export_rejects_unknown_request_fields(self):
        config = config_model.default_config()
        status, payload = self.call('/api/export', 'POST', {'config': config, 'unexpected': 1})
        self.assertEqual(status, 400)
        self.assertEqual(payload['error']['code'], 'invalid_request')

    def test_import_rejects_password_values(self):
        status, payload = self.call('/api/import', 'POST', {'text': "HARBOR_PASSWORD='secret'\nNODES=''\n"})
        self.assertEqual(status, 400)
        self.assertEqual(payload['error']['code'], 'invalid_config')

    def test_requests_without_token_are_rejected(self):
        request = urllib.request.Request('http://127.0.0.1:%d/api/schema' % self.port)
        try:
            urllib.request.urlopen(request, timeout=10)
            self.fail('expected 401')
        except urllib.error.HTTPError as error:
            self.assertEqual(error.code, 401)


class FakeExecution:
    def __init__(self):
        self.calls = []

    def request(self, operation, body=None):
        self.calls.append((operation, body))
        if operation == 'capabilities':
            return {'enabled': True, 'operation': 'all', 'fresh_install_only': True,
                    'stop_mode': 'stage-boundary', 'confirmation': 'acknowledgement'}
        if operation == 'submit':
            return {'id': body['request_id'], 'state': 'queued'}
        if operation == 'ledger':
            return {'filename': 'environment-ledger.xlsx',
                    'data': base64.b64encode(b'PK-ledger-test').decode('ascii')}
        if operation == 'artifact_sha256':
            return {'sha256': 'a' * 64, 'bytes': 12, 'path': body['path']}
        if operation == 'probe_nodes':
            return {'ok': True, 'exit_code': 0, 'nodes': [{'name': 'node1', 'status': 'passed', 'arch': 'amd64', 'os_package': 'ubuntu-24.04-debs', 'conflicts': []}], 'global_errors': []}
        if operation == 'clusters':
            return {'clusters': [{'cluster_name': 'prod', 'expandable': True}]}
        if operation == 'expand_workers':
            return {'id': body['request_id'], 'state': 'queued', 'stage': 'add-workers'}
        return {'enabled': True}


class ExecutionSubmitContractTests(HTTPCase):
    """The HTTP submit body must match the page payload and ExecutionService."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix='rise-web-submit-', dir='/tmp')
        cls.token = 'test-token-' + 'z' * 32
        cls.execution = FakeExecution()
        cls.httpd = server.make_server(ROOT, cls.tmp, 0, token=cls.token, execution=cls.execution)
        cls.port = cls.httpd.server_port
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=5)
        shutil.rmtree(cls.tmp, True)

    def payload(self, **overrides):
        body = {'request_id': str(uuid.uuid4()), 'plan_id': 'plan-1',
                'config_sha256': 'a' * 64, 'acknowledged': True,
                'credentials': {'harbor': 'Abcdef123456'}, 'debug': True}
        body.update(overrides)
        return body

    def test_submit_passes_acknowledged_and_debug_to_executor(self):
        body = self.payload()
        status, payload = self.call('/api/jobs', 'POST', body)
        self.assertEqual(status, 200)
        self.assertEqual(payload['id'], body['request_id'])
        operation, forwarded = self.execution.calls[-1]
        self.assertEqual(operation, 'submit')
        self.assertIs(forwarded['acknowledged'], True)
        self.assertIs(forwarded['debug'], True)
        self.assertNotIn('confirmation', forwarded)

    def test_submit_rejects_legacy_confirmation_body(self):
        body = self.payload()
        body.pop('acknowledged')
        body.pop('debug')
        body['confirmation'] = '我确认部署'
        status, payload = self.call('/api/jobs', 'POST', body)
        self.assertEqual(status, 400)
        self.assertEqual(payload['error']['code'], 'invalid_request')

    def test_execution_reports_enabled(self):
        status, payload = self.call('/api/execution')
        self.assertEqual(status, 200)
        self.assertTrue(payload['enabled'])

    def test_preview_forwards_requested_stage(self):
        config = config_model.default_config()
        status, payload = self.call('/api/jobs/preview', 'POST', {'config': config, 'stage': 'prepare'})
        self.assertEqual(status, 200)
        operation, forwarded = self.execution.calls[-1]
        self.assertEqual(operation, 'preview')
        self.assertEqual(forwarded['stage'], 'prepare')

    def test_submit_forwards_requested_stage(self):
        body = self.payload(stage='harbor')
        status, payload = self.call('/api/jobs', 'POST', body)
        self.assertEqual(status, 200)
        operation, forwarded = self.execution.calls[-1]
        self.assertEqual(operation, 'submit')
        self.assertEqual(forwarded['stage'], 'harbor')

    def test_artifact_sha256_endpoint_requires_executor_and_valid_body(self):
        status, payload = self.call('/api/execution/artifact-sha256', 'POST', {'path': '/tmp/artifact.tgz'})
        self.assertEqual(status, 200)
        self.assertEqual(payload['sha256'], 'a' * 64)
        status, payload = self.call('/api/execution/artifact-sha256', 'POST', {'path': 1})
        self.assertEqual(status, 400)
        self.assertEqual(payload['error']['code'], 'invalid_path')

    def test_artifact_sha256_endpoint_without_executor_is_not_silently_successful(self):
        disabled_tmp = tempfile.mkdtemp(prefix='rise-web-no-exec-', dir='/tmp')
        httpd = server.make_server(ROOT, disabled_tmp, 0, token=self.token)
        port = httpd.server_port
        thread = threading.Thread(target=httpd.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True)
        thread.start()
        try:
            request = urllib.request.Request('http://127.0.0.1:%d/api/execution/artifact-sha256' % port,
                                             data=b'{"path":"/tmp/a.tgz"}', method='POST')
            request.add_header('X-Web-Token', self.token)
            request.add_header('Content-Type', 'application/json')
            request.add_header('Origin', 'http://127.0.0.1:%d' % port)
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=10)
            self.assertEqual(caught.exception.code, 404)
        finally:
            httpd.shutdown(); httpd.server_close(); thread.join(timeout=5)
            shutil.rmtree(disabled_tmp, True)

    def test_ledger_download_is_binary_and_named(self):
        request = urllib.request.Request('http://127.0.0.1:%d/api/ledger' % self.port)
        request.add_header('X-Web-Token', self.token)
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers.get_content_type(),
                             'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
            self.assertIn('environment-ledger.xlsx', response.headers.get('Content-Disposition', ''))
            self.assertEqual(response.read(), b'PK-ledger-test')

    def test_probe_clusters_and_expand_workers_routes(self):
        config = config_model.default_config()
        status, payload = self.call('/api/execution/probe-nodes', 'POST', {'config': config, 'credentials': {}})
        self.assertEqual(status, 200)
        self.assertTrue(payload['ok'])
        status, payload = self.call('/api/execution/clusters')
        self.assertEqual(status, 200)
        self.assertEqual(payload['clusters'][0]['cluster_name'], 'prod')
        status, payload = self.call('/api/execution/expand-workers', 'POST', {
            'request_id': str(uuid.uuid4()), 'cluster_name': 'prod',
            'new_nodes': [config['nodes'][0]], 'credentials': {}, 'debug': False,
        })
        self.assertEqual(status, 200)
        self.assertEqual(payload['stage'], 'add-workers')


if __name__ == '__main__':
    unittest.main()
