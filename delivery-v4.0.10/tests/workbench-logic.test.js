const assert = require('assert');
const logic = require('../web/static/workbench-logic.js');

assert.strictEqual(logic.nextNodeName('k8s-node1', ['k8s-node1']), 'k8s-node2');
assert.strictEqual(logic.nextNodeName('k8s-node9', ['k8s-node9']), 'k8s-node10');
assert.strictEqual(logic.nextNodeName('k8s-node', ['k8s-node']), 'k8s-node2');
assert.strictEqual(logic.nextNodeName('node2', ['node2', 'node3']), 'node4');
assert.strictEqual(logic.nextIPv4('192.168.10.11'), '192.168.10.12');
assert.strictEqual(logic.nextIPv4('192.168.10.254'), '192.168.11.1');
assert.strictEqual(logic.nextIPv4('not-an-ip'), '');
assert.strictEqual(logic.ruleVisible({field: 'DEPS_MODE', in: ['iso', 'bootstrap']}, {DEPS_MODE: 'iso'}), true);
assert.strictEqual(logic.ruleVisible({field: 'DEPS_MODE', notIn: ['online']}, {DEPS_MODE: 'online'}), false);
assert.strictEqual(logic.ruleVisible({field: 'NTP_MODE', equals: 'node'}, {NTP_MODE: 'external'}), false);
assert.strictEqual(logic.ruleVisible({all: [{field: 'COMPONENTS', in: ['all']}, {field: 'REGISTRY_MODE', equals: 'ha-harbor'}]}, {COMPONENTS: 'all', REGISTRY_MODE: 'ha-harbor'}), true);
const links = logic.storageLinks('/data');
assert.strictEqual(links.filter((row) => row.name === 'containerd')[0].target, '/data/containerd');
assert.strictEqual(links.filter((row) => row.name === 'kubelet')[0].target, '/data/kubelet');
assert.strictEqual(links.filter((row) => row.name === 'etcd').length, 0);
assert.strictEqual(links.filter((row) => row.name === 'registry (Harbor)')[0].target, '/data/harbor');
assert.strictEqual(logic.storageLinks('/data/')[0].target, '/data/containerd');
assert.deepStrictEqual(logic.storageLinks('/data', 'native'), []);
assert.strictEqual(logic.storageLinks('/data', 'existing')[0].target, '/data/containerd');
assert.strictEqual(logic.storageLinks('/data', 'existing', {localStorage: true, localPath: '/data/local-pv', nfsMode: 'none'}).filter((row) => row.name === 'local-pv').length, 1);
const config = {
  settings: {DEPS_MODE: 'online', ARTIFACT_FILE: '/x', NTP_MODE: 'external', NTP_NODE: 'node1', SSH_AUTH_MODE: 'key'},
  nodes: [
    {name: 'n1', connection: 'local', user: 'root', port: 22, password_env: 'N1', data_mode: 'native', device: '/dev/x'},
    {name: 'n2', connection: 'ssh', user: 'root', port: 22, password_env: 'N2', data_mode: 'format', device: '/dev/y'}
  ]
};
const rules = {
  ARTIFACT_FILE: {field: 'DEPS_MODE', notIn: ['online']},
  NTP_NODE: {field: 'NTP_MODE', equals: 'node'}
};
const pruned = logic.pruneConfig(config, rules, 'key');
assert.strictEqual('ARTIFACT_FILE' in pruned.settings, false);
assert.strictEqual('NTP_NODE' in pruned.settings, false);
assert.strictEqual('user' in pruned.nodes[0], false);
assert.strictEqual('port' in pruned.nodes[0], false);
assert.strictEqual('password_env' in pruned.nodes[0], false);
assert.strictEqual('device' in pruned.nodes[0], false);
assert.strictEqual('password_env' in pruned.nodes[1], false);
assert.strictEqual(pruned.nodes[1].device, '/dev/y');
assert.strictEqual('password' in pruned.nodes[1], false);
const localOnly = logic.pruneConfig({settings: {SSH_AUTH_MODE: 'bootstrap', SSH_KEY: '/root/key'}, nodes: [{name: 'n1', connection: 'local'}]}, {}, 'bootstrap');
assert.strictEqual('SSH_AUTH_MODE' in localOnly.settings, false);
assert.strictEqual('SSH_KEY' in localOnly.settings, false);

// any combinator & declarative schemaRules
assert.strictEqual(logic.ruleVisible({any: [{field: 'COMPONENTS', equals: 'k8s'}, {field: 'REGISTRY_MODE', equals: 'external-harbor'}]}, {COMPONENTS: 'k8s', REGISTRY_MODE: 'harbor'}), true);
assert.strictEqual(logic.ruleVisible({any: [{field: 'COMPONENTS', equals: 'k8s'}, {field: 'REGISTRY_MODE', equals: 'external-harbor'}]}, {COMPONENTS: 'all', REGISTRY_MODE: 'harbor'}), false);

const fs = require('fs');
const path = require('path');
const rawSchema = JSON.parse(fs.readFileSync(path.join(__dirname, '../web/schema.json'), 'utf8'));
const derivedRules = logic.schemaRules(rawSchema);
const extHarbor = logic.pruneConfig({
  settings: {
    COMPONENTS: 'k8s',
    REGISTRY_MODE: 'external-harbor',
    HARBOR_ADDRESS: '192.0.2.50',
    HARBOR_DOMAIN: 'harbor.corp.example',
    HARBOR_PORT: 443,
    HARBOR_HTTP: false,
    HARBOR_CA: '/etc/ssl/certs/harbor-ca.pem',
    INSTALL_NERDCTL: true
  },
  nodes: [{name: 'm1', connection: 'ssh', user: 'root', port: 22, roles: ['control_plane', 'worker', 'etcd'], data_mode: 'native'}]
}, derivedRules, 'key');
assert.strictEqual(extHarbor.settings.REGISTRY_MODE, 'external-harbor');
assert.strictEqual(extHarbor.settings.HARBOR_ADDRESS, '192.0.2.50');
assert.strictEqual(extHarbor.settings.HARBOR_DOMAIN, 'harbor.corp.example');
assert.strictEqual(extHarbor.settings.HARBOR_CA, '/etc/ssl/certs/harbor-ca.pem');
assert.strictEqual(extHarbor.settings.INSTALL_NERDCTL, true);

// Master/Etcd co-located odd-quorum validation (1, 3, 5, 7...)
function makeMasters(n, withEtcd = true) {
  const arr = [];
  for (let i = 1; i <= n; i += 1) {
    arr.push({name: 'm' + i, roles: withEtcd ? ['control_plane', 'etcd', 'worker'] : ['control_plane', 'worker']});
  }
  return arr;
}
assert.strictEqual(logic.validateMasterEtcdTopology(makeMasters(1), 'all').valid, true);
assert.strictEqual(logic.validateMasterEtcdTopology(makeMasters(3), 'all').valid, true);
assert.strictEqual(logic.validateMasterEtcdTopology(makeMasters(5), 'all').valid, true);
assert.strictEqual(logic.validateMasterEtcdTopology(makeMasters(7), 'k8s').valid, true);
assert.strictEqual(logic.validateMasterEtcdTopology([], 'all').valid, false);
assert.strictEqual(logic.validateMasterEtcdTopology(makeMasters(2), 'all').valid, false);
assert.strictEqual(logic.validateMasterEtcdTopology(makeMasters(4), 'all').valid, false);
assert.strictEqual(logic.validateMasterEtcdTopology([{name: 'm1', roles: ['control_plane', 'etcd']}, {name: 'm2', roles: ['control_plane']}, {name: 'm3', roles: ['control_plane', 'etcd']}], 'all').valid, false);
assert.strictEqual(logic.validateMasterEtcdTopology([{name: 'w1', roles: ['worker', 'etcd']}, {name: 'm1', roles: ['control_plane', 'etcd']}], 'all').valid, false);
assert.strictEqual(logic.validateMasterEtcdTopology([{name: 'r1', roles: ['registry']}], 'harbor').valid, true);

// Role sync helper
assert.deepStrictEqual(logic.syncMasterEtcdRoles(['worker'], 'control_plane', true), ['worker', 'control_plane', 'etcd']);
assert.deepStrictEqual(logic.syncMasterEtcdRoles(['control_plane', 'etcd', 'worker'], 'control_plane', false), ['worker']);
assert.deepStrictEqual(logic.syncMasterEtcdRoles(['worker'], 'etcd', true), ['worker', 'control_plane', 'etcd']);
assert.deepStrictEqual(logic.syncMasterEtcdRoles(['control_plane', 'etcd', 'registry'], 'etcd', false), ['registry']);

console.log('WORKBENCH_LOGIC_OK');
