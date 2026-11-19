"""Static UI contract checks for the three-step wizard without a browser."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / 'web' / 'static' / 'index.html').read_text(encoding='utf-8')
APP = (ROOT / 'web' / 'static' / 'app.js').read_text(encoding='utf-8')
CSS = (ROOT / 'web' / 'static' / 'style.css').read_text(encoding='utf-8')
LOGIC = (ROOT / 'web' / 'static' / 'workbench-logic.js').read_text(encoding='utf-8')


class WorkbenchUIContractTests(unittest.TestCase):
    def test_three_step_navigation_and_help_dialog(self):
        for label in ('填写配置', '校验与计划', '执行与台账'):
            self.assertIn(label, HTML)
        self.assertIn('data-step-target="1"', HTML)
        self.assertIn('data-step-target="2"', HTML)
        self.assertIn('data-step-target="3"', HTML)
        self.assertIn('id="help-dialog"', HTML)
        self.assertIn('id="open-help"', HTML)
        self.assertIn('.wizard-shell', CSS)

    def test_matrix_preview_and_stage_controls(self):
        self.assertIn('node-matrix', APP)
        self.assertIn('data-node-primary-field', APP)
        self.assertIn('storageLinks', APP)
        self.assertIn('derived-links', CSS)
        self.assertIn('id="view-env"', HTML)
        self.assertIn('id="env-preview"', HTML)
        self.assertIn('setConfigView', APP)
        self.assertIn('id="stage-prepare"', HTML)
        self.assertIn('id="stage-harbor"', HTML)
        self.assertIn('id="stage-k8s"', HTML)
        self.assertIn('id="stop-current-job"', HTML)
        self.assertIn('id="stage-progress"', HTML)
        self.assertIn('renderStageProgress', APP)
        self.assertIn('repeat(3', CSS)

    def test_global_section_and_inline_harbor_credentials(self):
        self.assertIn('全局配置与集群参数', HTML)
        self.assertIn('id="basic-settings"', HTML)
        self.assertNotIn('credentials-fields', HTML)
        self.assertNotIn('credentials-fields', APP)
        self.assertIn('harbor-password-header', APP)
        self.assertIn('harborPasswordControl', APP)
        self.assertIn('matrix-harbor-password', APP)
        self.assertIn('node-expand', APP)
        self.assertIn('节点矩阵', HTML)

    def test_master_harbor_and_ssh_boundaries(self):
        self.assertIn('id="master-count-status"', HTML)
        self.assertIn('id="master-count-error"', HTML)
        self.assertIn('id="harbor-count-error"', HTML)
        self.assertIn('id="master-count-status"', HTML)
        self.assertIn('ENDPOINT_ADDRESS', APP)
        self.assertIn('setting-SSH_AUTO_KEY', APP)
        self.assertIn('自动在控制端生成默认 SSH 密钥对', APP)
        self.assertIn('masterValid', APP)
        self.assertIn('harborRoleValid', APP)
        self.assertIn('APISERVER_VIP', APP)
        self.assertIn('masterValid', APP)
        self.assertIn('normalizeHarborRoles', APP)
        self.assertIn('harborRoleValid', APP)
        self.assertIn('setting-SSH_AUTO_KEY', APP)
        self.assertIn('自动在控制端生成默认 SSH 密钥对', APP)
        self.assertIn('SSH_AUTH_MODE', APP)
        self.assertIn('SSH_KEY', APP)

    def test_presets_and_direct_install(self):
        self.assertIn('id="preset-single"', HTML)
        self.assertIn('id="preset-ha"', HTML)
        self.assertIn('id="start-deploy-direct"', HTML)
        self.assertIn('applyPreset', APP)
        self.assertIn('startDeployDirect', APP)
        self.assertIn('/api/jobs', APP)
        self.assertIn('downloadLedger', APP)

    def test_inline_node_password_clone_and_dynamic_rules(self):
        self.assertIn('node-credential', APP)
        self.assertIn('克隆行', APP)
        self.assertIn('node-clone', CSS)
        self.assertIn('data-show-when', APP)
        self.assertIn('setHidden', APP)
        self.assertIn('pruneConfig', APP)
        self.assertIn('ruleVisible', LOGIC)
        self.assertIn('nextNodeName', LOGIC)
        self.assertIn('nextIPv4', LOGIC)

    def test_manual_sha_control_is_removed_and_automatic_note_exists(self):
        self.assertNotIn('compute-artifact-sha', HTML)
        self.assertNotIn('computeArtifactSha', APP)
        self.assertIn('ARTIFACT_SHA256', APP)
        self.assertIn('离线归档 SHA256', HTML)
        self.assertNotIn('artifact-auto-note', HTML)
        self.assertIn('artifact_digest', APP + (ROOT / 'web' / 'server.py').read_text(encoding='utf-8'))

    def test_draft_ui_is_removed_and_env_io_is_present(self):
        for token in ('draft-name', 'draft-list', 'save-draft', 'refresh-drafts'):
            self.assertNotIn(token, HTML)
            self.assertNotIn(token, APP)
        self.assertIn('id="export-env"', HTML)
        self.assertIn('id="import-env"', HTML)
        self.assertIn('/api/export', APP)
        self.assertIn('/api/import', APP)
        self.assertIn('history.replaceState', APP)
        self.assertIn('beforeunload', APP)

    def test_node_probe_and_managed_clusters_worker_expansion_ui_exist(self):
        self.assertIn('id="probe-nodes"', HTML)
        self.assertIn('id="probe-results"', HTML)
        self.assertIn('id="managed-clusters-panel"', HTML)
        self.assertIn('id="refresh-clusters"', HTML)
        self.assertIn('id="submit-expand-workers"', HTML)
        self.assertIn('/api/execution/probe-nodes', APP)
        self.assertIn('/api/execution/clusters', APP)
        self.assertIn('/api/execution/expand-workers', APP)
        self.assertIn('probeNodes', APP)
        self.assertIn('refreshClusters', APP)
        self.assertIn('submitExpandWorkers', APP)


if __name__ == '__main__':
    unittest.main()
