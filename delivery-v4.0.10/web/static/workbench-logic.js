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
    if (Array.isArray(rule.all)) return rule.all.every((part) => ruleVisible(part, values));
    const value = values && values[rule.field];
    if (rule.equals !== undefined && value !== rule.equals) return false;
    if (rule.notEquals !== undefined && value === rule.notEquals) return false;
    if (Array.isArray(rule.in) && !rule.in.includes(value)) return false;
    if (Array.isArray(rule.notIn) && rule.notIn.includes(value)) return false;
    return true;
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
    copy.nodes = (copy.nodes || []).map((node) => {
      const row = JSON.parse(JSON.stringify(node));
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
  return {nextNodeName: nextNodeName, nextIPv4: nextIPv4, storageLinks: storageLinks, ruleVisible: ruleVisible, pruneConfig: pruneConfig};
});
