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
console.log('WORKBENCH_LOGIC_OK');
