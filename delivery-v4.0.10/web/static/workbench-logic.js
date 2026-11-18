/* Pure, DOM-free workbench rules shared by the browser and Node tests. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.RiseWorkbenchLogic = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  function nextNodeName(baseName, usedNames) {
    const used = new Set(usedNames || []);
    const base = String(baseName || 'node');
    const match = /^(.*?)(\d+)$/.exec(base);
    let candidate;
    if (match) {
      let number = Number(match[2]) + 1;
      do { candidate = match[1] + number; number += 1; } while (used.has(candidate));
    } else {
      let number = 2;
      do { candidate = base + number; number += 1; } while (used.has(candidate));
    }
    return candidate;
  }
  function nextIPv4(address) {
    const parts = String(address || '').split('.');
    if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) return '';
    const octets = parts.map((part) => Number(part));
    if (octets.some((part) => part < 0 || part > 255)) return '';
    octets[3] += 1;
    if (octets[3] > 254) { octets[3] = 1; octets[2] += 1; }
    if (octets[2] > 254) { octets[2] = 1; octets[1] += 1; }
    if (octets[1] > 254) return '';
    return octets.join('.');
  }
  function storageLinks(dataPath, dataMode, options) {
    if (String(dataMode == null ? '' : dataMode) === 'native') return [];
    let base = String(dataPath == null ? '' : dataPath).trim();
    if (!base || base === '/') base = '/data';
    base = base.replace(/\/+$/, '');
    const opts = options || {};
    const links = [
      {source: '/var/lib/containerd', name: 'containerd', target: base + '/containerd'},
      {source: '/var/lib/kubelet', name: 'kubelet', target: base + '/kubelet'},
      {source: '/var/lib/docker', name: 'docker', target: base + '/docker'},
      {source: '/var/lib/harbor/data', name: 'registry (Harbor)', target: base + '/harbor'}
    ];
    if (opts.localStorage && opts.localPath) links.push({source: 'local-pv', name: 'local-pv', target: String(opts.localPath)});
    if (opts.nfsMode && opts.nfsMode !== 'none' && opts.nfsPath) links.push({source: 'nfs', name: 'nfs', target: String(opts.nfsPath)});
    return links;
  }
  function ruleVisible(rule, values) {
    if (!rule) return true;
    if (Array.isArray(rule.all)) return rule.all.every((part) => ruleVisible(part, values));
    if (Array.isArray(rule.any)) return rule.any.some((part) => ruleVisible(part, values));
    const value = values && values[rule.field];
    if (rule.equals !== undefined && value !== rule.equals) return false;
    if (rule.notEquals !== undefined && value === rule.notEquals) return false;
    if (Array.isArray(rule.in) && !rule.in.includes(value)) return false;
    if (Array.isArray(rule.notIn) && rule.notIn.includes(value)) return false;
    return true;
  }
  function schemaRules(schemaObj) {
    const map = {};
    const settings = schemaObj && Array.isArray(schemaObj.settings) ? schemaObj.settings : [];
    settings.forEach((field) => {
      if (field && field.key && field.visible_when) map[field.key] = field.visible_when;
    });
    return map;
  }
  function syncMasterEtcdRoles(roles, toggledRole, checked) {
    const current = Array.isArray(roles) ? roles.slice() : [];
    if (toggledRole !== 'control_plane' && toggledRole !== 'etcd') {
      const idx = current.indexOf(toggledRole);
      if (checked && idx < 0) current.push(toggledRole);
      if (!checked && idx >= 0) current.splice(idx, 1);
      return current;
    }
    const filtered = current.filter((role) => role !== 'control_plane' && role !== 'etcd');
    if (checked) {
      filtered.push('control_plane', 'etcd');
    }
    return filtered;
  }
  function validateMasterEtcdTopology(nodes, components) {
    const list = Array.isArray(nodes) ? nodes : [];
    let masterCount = 0;
    let etcdCount = 0;
    for (let i = 0; i < list.length; i += 1) {
      const roles = Array.isArray(list[i] && list[i].roles) ? list[i].roles : [];
      const hasMaster = roles.indexOf('control_plane') >= 0;
      const hasEtcd = roles.indexOf('etcd') >= 0;
      if (hasEtcd && !hasMaster) {
        return {
          valid: false,
          masterCount: masterCount,
          etcdCount: etcdCount + 1,
          coLocated: false,
          reason: 'Etcd 必须与 Master 同机部署，禁止在非 Master 节点单独勾选 Etcd。'
        };
      }
      if (hasMaster) masterCount += 1;
      if (hasEtcd) etcdCount += 1;
    }
    if (components === 'harbor') {
      return {valid: true, masterCount: masterCount, etcdCount: etcdCount, coLocated: true, reason: ''};
    }
    if (etcdCount > 0 && etcdCount !== masterCount) {
      return {
        valid: false,
        masterCount: masterCount,
        etcdCount: etcdCount,
        coLocated: false,
        reason: 'Master 与 Etcd 必须同机一一对应（当前 Master：' + masterCount + '，Etcd：' + etcdCount + '）。'
      };
    }
    if (masterCount < 1 || masterCount % 2 === 0) {
      return {
        valid: false,
        masterCount: masterCount,
        etcdCount: etcdCount,
        coLocated: true,
        reason: 'Master 与 Etcd 节点数量必须为 1、3、5… 正奇数（当前为 ' + masterCount + '），偶数节点存在高可用脑裂风险。'
      };
    }
    return {valid: true, masterCount: masterCount, etcdCount: etcdCount || masterCount, coLocated: true, reason: ''};
  }
  function pruneConfig(config, rules, authMode) {
    const copy = JSON.parse(JSON.stringify(config));
    Object.keys(rules || {}).forEach((key) => {
      if (!ruleVisible(rules[key], copy.settings)) delete copy.settings[key];
    });
    if (!(copy.nodes || []).some((node) => node.connection === 'ssh')) {
      delete copy.settings.SSH_AUTH_MODE;
      delete copy.settings.SSH_KEY;
    }
    const allNodes = copy.nodes || [];
    const anyExplicitEtcd = allNodes.some((node) => Array.isArray(node.roles) && node.roles.indexOf('etcd') >= 0);
    copy.nodes = allNodes.map((node) => {
      const row = JSON.parse(JSON.stringify(node));
      if (!anyExplicitEtcd && Array.isArray(row.roles) && row.roles.indexOf('control_plane') >= 0 && row.roles.indexOf('etcd') < 0) {
        row.roles.push('etcd');
      }
      if (row.connection === 'local') {
        delete row.user; delete row.port; delete row.password_env;
      } else if (authMode !== 'password') {
        delete row.password_env;
      }
      if (row.data_mode !== 'format') delete row.device;
      return row;
    });
    return copy;
  }
  return {
    nextNodeName: nextNodeName,
    nextIPv4: nextIPv4,
    storageLinks: storageLinks,
    ruleVisible: ruleVisible,
    schemaRules: schemaRules,
    syncMasterEtcdRoles: syncMasterEtcdRoles,
    validateMasterEtcdTopology: validateMasterEtcdTopology,
    pruneConfig: pruneConfig
  };
});
