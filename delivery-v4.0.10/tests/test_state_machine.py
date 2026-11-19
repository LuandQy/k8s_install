"""Contract tests proving CLI and Web share one execution/state path."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web'))
import execution  # noqa: E402


class StateMachineContractTests(unittest.TestCase):
    def test_cli_and_web_call_the_same_stage_workflow(self):
        deploy = (ROOT / 'deploy.sh').read_text(encoding='utf-8')
        runner = (ROOT / 'web' / 'execution.py').read_text(encoding='utf-8')
        server = (ROOT / 'web' / 'server.py').read_text(encoding='utf-8')
        workflow = (ROOT / 'lib' / 'workflow.sh').read_text(encoding='utf-8')
        state = (ROOT / 'lib' / 'cluster-state.sh').read_text(encoding='utf-8')
        self.assertIn('workflow_main', deploy)
        self.assertIn('workflow_main', workflow)
        self.assertIn("'cli', '--step', step", runner)
        self.assertIn("'prepare': ('access', 'prepare', 'deps', 'services-init', 'services-verify')", runner)
        self.assertIn("'harbor': ('harbor-install', 'harbor-projects', 'images-import', 'images-verify')", runner)
        self.assertIn("'k8s': ('k8s-install', 'node-images-verify', 'cluster-verify', 'ledger')", runner)
        self.assertIn('/api/ledger', server)
        self.assertIn('/api/execution/artifact-sha256', server)
        self.assertIn('artifact-sha256', deploy)
        self.assertIn('state', state.lower())
        self.assertIn('workflow_write_hosts', workflow)
        self.assertIn('node_scripts/hosts.sh', workflow)
        self.assertIn('component_sync_registry_ca', workflow)
        self.assertIn('node_scripts/registry-ca.sh', (ROOT / 'lib' / 'components.sh').read_text(encoding='utf-8'))
        self.assertTrue((ROOT / 'node_scripts' / 'hosts.sh').is_file())
        self.assertTrue((ROOT / 'node_scripts' / 'registry-ca.sh').is_file())
        self.assertIn("'prepare': ('access', 'prepare', 'deps', 'services-init', 'services-verify')", runner)

    def test_web_runner_uses_cli_step_and_debug(self):
        class Stream:
            def __init__(self):
                self.file = tempfile.TemporaryFile()
                self.file.write(b'ok\n')
                self.file.seek(0)
            def fileno(self):
                return self.file.fileno()

        class Child:
            def __init__(self):
                self.stdout = Stream()
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.stdout.file.close()
                return False
            def wait(self):
                return 0

        class Popen:
            called = None
            def __new__(cls, argv, **kwargs):
                cls.called = (argv, kwargs)
                return Child()

        config = Path(tempfile.mkdtemp(prefix='rise-state-')) / 'site.env'
        config.write_text('CLUSTER_NAME=test\n', encoding='utf-8')
        job = {'config_path': str(config), 'debug': True}
        with mock.patch.object(execution.subprocess, 'Popen', Popen):
            rc = execution.CLIRunner(str(ROOT))(job, {'PATH': '/usr/bin:/bin'}, lambda _data: None)
        self.assertEqual(rc, 0)
        argv, kwargs = Popen.called
        self.assertEqual(argv[0], '/bin/bash')
        deploy_index = next(i for i, item in enumerate(argv) if item.endswith('/deploy.sh'))
        self.assertEqual(argv[deploy_index + 1:deploy_index + 5],
                         ['cli', '--step', 'all', '--env'])
        self.assertIn('--non-interactive', argv)
        self.assertIn('--debug', argv)
        self.assertEqual(kwargs['env']['RISE_LOG_LEVEL'], 'debug')

    def test_web_runner_runs_stage_sequence(self):
        class Stream:
            def __init__(self):
                self.file = tempfile.TemporaryFile()
                self.file.write(b'ok\n')
                self.file.seek(0)
            def fileno(self):
                return self.file.fileno()
        class Child:
            def __init__(self):
                self.stdout = Stream()
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.stdout.file.close()
                return False
            def wait(self):
                return 0
        calls = []
        class Popen:
            def __new__(cls, argv, **kwargs):
                calls.append(argv)
                return Child()
        config = Path(tempfile.mkdtemp(prefix='rise-stage-')) / 'site.env'
        config.write_text('CLUSTER_NAME=test\n', encoding='utf-8')
        job = {'config_path': str(config), 'debug': False, 'stage': 'prepare'}
        with mock.patch.object(execution.subprocess, 'Popen', Popen):
            rc = execution.CLIRunner(str(ROOT))(job, {'PATH': '/usr/bin:/bin'}, lambda _data: None)
        self.assertEqual(rc, 0)
        steps = [argv[argv.index('--step') + 1] for argv in calls]
        self.assertEqual(steps, ['access', 'prepare', 'deps', 'services-init', 'services-verify'])

    def test_web_runner_runs_add_workers_expansion(self):
        class Stream:
            def __init__(self):
                self.file = tempfile.TemporaryFile()
                self.file.write(b'expanded\n')
                self.file.seek(0)
            def fileno(self):
                return self.file.fileno()
        class Child:
            def __init__(self):
                self.stdout = Stream()
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.stdout.file.close()
                return False
            def wait(self):
                return 0
        calls = []
        class Popen:
            def __new__(cls, argv, **kwargs):
                calls.append((argv, kwargs))
                return Child()
        tmp = Path(tempfile.mkdtemp(prefix='rise-expand-'))
        workers = tmp / 'workers.env'
        workers.write_text("NEW_NODES='w2|192.0.2.2|192.0.2.2|root|22|amd64|ubuntu-24.04-debs|worker|ssh|/data|native||'\n", encoding='utf-8')
        job = {'stage': 'add-workers', 'state_dir': str(tmp / 'state'), 'workers_path': str(workers), 'debug': True}
        with mock.patch.object(execution.subprocess, 'Popen', Popen):
            rc = execution.CLIRunner(str(ROOT))(job, {'PATH': '/usr/bin:/bin'}, lambda _data: None)
        self.assertEqual(rc, 0)
        argv, kwargs = calls[0]
        self.assertIn('add-workers', argv)
        self.assertIn('--state-dir', argv)
        self.assertIn('--nodes', argv)
        self.assertIn('-y', argv)
        self.assertNotIn('--debug', argv)
        self.assertEqual(kwargs['env']['RISE_LOG_LEVEL'], 'debug')


if __name__ == '__main__':
    unittest.main()
