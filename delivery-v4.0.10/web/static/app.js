/* Three-step deployment wizard. Keeps field names aligned with CLI env. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const clone = (value) => JSON.parse(JSON.stringify(value));
  const TOKEN_KEY = 'rise-wizard-token';
  const BASIC_KEYS = ['CLUSTER_NAME', 'COMPONENTS', 'DEPS_MODE', 'ARTIFACT_FILE', 'KUBE_VERSION',
    'INSTALL_NERDCTL', 'ENDPOINT_TYPE', 'ENDPOINT_ADDRESS', 'SSH_AUTH_MODE', 'NTP_MODE', 'NTP_NODE', 'NTP_SERVERS',
    'NFS_MODE', 'NFS_NODE', 'NFS_SERVER', 'NFS_PATH', 'REGISTRY_MODE', 'HARBOR_ADDRESS', 'HARBOR_DOMAIN', 'HARBOR_PORT'];
  const HARBOR_KEYS = ['REGISTRY_MODE', 'IMPORT_IMAGES', 'HARBOR_ADDRESS', 'HARBOR_DOMAIN',
    'HARBOR_PORT', 'HARBOR_HTTP', 'HARBOR_VIP', 'HARBOR_VRRP_ID', 'HARBOR_SOURCE_DIR',
    'HARBOR_CA', 'HARBOR_CERT', 'HARBOR_KEY'];
  function activeRules() {
    return state.schema ? logic.schemaRules(state.schema) : {};
  }
  const nodeRules = {
    user: (node) => node.connection === 'ssh',
    port: (node) => node.connection === 'ssh',
    password: (node) => nodeNeedsPassword(node),
    password_env: (node) => node.connection === 'ssh' && authMode() === 'password',
    device: (node) => node.data_mode === 'format'
  };
  const logic = window.RiseWorkbenchLogic;
  const state = {
    schema: null, defaults: null, suggestions: {}, config: null,
    dirty: false, generation: 0, busy: false, credentials: {harbor: '', nodes: new Map()},
    showPasswords: false, step: 1, capability: null, jobs: [], job: null, poll: null,
    offset: 0, log: '', executorLoading: false, envView: false,
    clusters: [], expandTarget: null
  };
  let token = '';

  function authMode() {
    return state.config && state.config.settings ? state.config.settings.SSH_AUTH_MODE : 'bootstrap';
  }
  function harborEnabled() {
    return Boolean(state.config && state.config.settings && ['all', 'harbor'].includes(state.config.settings.COMPONENTS));
  }
  function nodeNames() {
    return (state.config && state.config.nodes || []).map((node) => node.name).filter(Boolean);
  }
  function el(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined && text !== null) node.textContent = String(text);
    if (className) node.className = className;
    return node;
  }
  function notice(message, type) {
    const area = $('notice');
    area.textContent = message || '';
    area.className = 'notice' + (type ? ' ' + type : '');
    area.hidden = !message;
  }
  function setBusy(value) {
    state.busy = Boolean(value);
    document.querySelectorAll('button:not([data-always-enabled])').forEach((button) => { button.disabled = value; });
    if (!value) {
      document.querySelectorAll('button:not([data-always-enabled])').forEach((button) => { button.disabled = false; });
      syncButtons();
    }
  }
  async function api(path, method, body, timeoutMs) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs || 30000);
    try {
      const headers = {'X-Web-Token': token};
      const options = {method: method || 'GET', headers: headers, credentials: 'omit', cache: 'no-store', signal: controller.signal};
      if (body !== undefined) {
        headers['Content-Type'] = 'application/json';
        options.body = JSON.stringify(body);
      }
      const response = await fetch(path, options);
      let data = null;
      try { data = await response.json(); } catch (_) { data = null; }
      if (!response.ok) {
        const message = data && data.error && data.error.message ? data.error.message : '请求失败（HTTP ' + response.status + '）';
        const error = new Error(message); error.status = response.status; error.code = data && data.error ? data.error.code : ''; throw error;
      }
      return data;
    } catch (error) {
      if (error.name === 'AbortError') throw new Error('请求超时，结果未确认；请刷新草稿或任务列表核对，不要重复提交。');
      throw error;
    } finally { clearTimeout(timeout); }
  }
  function optionLabel(field, value) {
    const labels = field.option_labels || {};
    return labels[String(value)] ? labels[String(value)] + '（' + value + '）' : String(value);
  }
  function optionHelp(field, value) {
    return (field.option_help || {})[String(value)] || '';
  }
  function typeValue(input, field) {
    if (field.type === 'boolean') return input.checked;
    if (field.type === 'integer') return input.value === '' ? '' : Number(input.value);
    return input.value;
  }
  function ruleVisible(rule) {
    return logic.ruleVisible(rule, state.config.settings);
  }
  function setHidden(holder, hidden) {
    holder.hidden = hidden;
    holder.querySelectorAll('input,select,textarea').forEach((control) => { control.disabled = hidden; });
  }
  function masterTopology() {
    const components = state.config && state.config.settings ? state.config.settings.COMPONENTS : 'all';
    return logic.validateMasterEtcdTopology(state.config && state.config.nodes || [], components);
  }
  function masterCount() {
    return masterTopology().masterCount;
  }
  function masterValid() {
    return masterTopology().valid;
  }
  function registryMode() {
    return state.config && state.config.settings ? state.config.settings.REGISTRY_MODE : 'harbor';
  }
  function harborManaged() {
    return Boolean(state.config && state.config.settings && ['all', 'harbor'].includes(state.config.settings.COMPONENTS));
  }
  function harborRoleCount() {
    return (state.config && state.config.nodes || []).reduce((count, node) => count + (Array.isArray(node.roles) && node.roles.indexOf('registry') >= 0 ? 1 : 0), 0);
  }
  function harborRoleValid() {
    if (!harborManaged() || registryMode() === 'external-harbor') return true;
    if (registryMode() === 'harbor') return harborRoleCount() === 1;
    return harborRoleCount() >= 2;
  }
  function normalizeHarborRoles() {
    if (!state.config) return;
    if (!harborManaged() || registryMode() === 'external-harbor') {
      state.config.nodes.forEach((node) => { node.roles = (node.roles || []).filter((role) => role !== 'registry'); });
      return;
    }
    if (registryMode() === 'harbor') {
      let found = false;
      state.config.nodes.forEach((node) => {
        if (!Array.isArray(node.roles)) node.roles = [];
        if (node.roles.indexOf('registry') >= 0) {
          if (found) node.roles = node.roles.filter((role) => role !== 'registry');
          else found = true;
        }
      });
    }
  }
  function applyMasterRules() {
    if (!state.config || !state.config.settings) return;
    const topo = masterTopology();
    const count = topo.masterCount;
    const valid = topo.valid;
    const isHarborOnly = state.config.settings.COMPONENTS === 'harbor';
    const status = $('master-count-status');
    const error = $('master-count-error');
    if (status) {
      status.textContent = isHarborOnly
        ? 'Master/Etcd：纯 Harbor 模式免配'
        : ('Master/Etcd：' + count + '/' + topo.etcdCount + (valid ? '（奇数高可用就绪）' : '（须同机且为 1、3、5… 正奇数）'));
      status.className = 'status-chip ' + (valid ? 'valid' : 'invalid');
    }
    if (error) {
      error.hidden = valid;
      error.textContent = valid ? '' : topo.reason;
    }
    const type = state.config.settings.ENDPOINT_TYPE;
    const typeSelect = document.getElementById('setting-ENDPOINT_TYPE');
    if (!isHarborOnly && count === 1 && type === 'kube-vip') {
      state.config.settings.ENDPOINT_TYPE = 'local';
      if (typeSelect) typeSelect.value = 'local';
    } else if (!isHarborOnly && count >= 3 && type === 'local') {
      state.config.settings.ENDPOINT_TYPE = 'kube-vip';
      if (typeSelect) typeSelect.value = 'kube-vip';
    }
    const effectiveType = state.config.settings.ENDPOINT_TYPE;
    const vip = document.querySelector('[data-setting-key="ENDPOINT_ADDRESS"]');
    if (vip) {
      const needVip = !isHarborOnly && (effectiveType === 'kube-vip' || effectiveType === 'external');
      setHidden(vip, !needVip);
      const input = vip.querySelector('input');
      if (input) input.required = needVip;
    }
    applyHarborRules();
    syncButtons();
  }
  function applyHarborRules() {
    const error = $('harbor-count-error');
    if (!error) return;
    const valid = harborRoleValid();
    error.hidden = valid;
    if (valid) { error.textContent = ''; return; }
    error.textContent = registryMode() === 'harbor'
      ? '单节点受管 Harbor 模式必须且只能勾选 1 个 Harbor 节点。'
      : 'HA Harbor 模式至少需要勾选 2 个 Harbor 节点。';
  }
  function renderMasterStepError() {
    const area = $('results-content');
    const topo = masterTopology();
    $('result-status').textContent = '未通过'; $('result-status').className = 'status-chip invalid';
    area.replaceChildren(el('p', topo.reason || 'Master/Etcd 节点数量必须为 1、3、5… 正奇数且同机绑定。', 'result-errors'));
    $('next-step-3').disabled = true;
  }
  function renderHarborStepError() {
    const area = $('results-content');
    $('result-status').textContent = '未通过'; $('result-status').className = 'status-chip invalid';
    area.replaceChildren(el('p', registryMode() === 'harbor' ? '单节点受管 Harbor 模式必须且只能勾选 1 个 Harbor 节点。' : 'HA Harbor 模式至少需要勾选 2 个 Harbor 节点。', 'result-errors'));
    $('next-step-3').disabled = true;
  }
  function applyVisibility() {
    if (!state.config || !state.config.settings) return;
    document.querySelectorAll('[data-show-when]').forEach((holder) => {
      let rule;
      try { rule = JSON.parse(holder.dataset.showWhen); } catch (_) { return; }
      setHidden(holder, !ruleVisible(rule));
    });
    const anySsh = state.config.nodes.some((node) => node.connection === 'ssh');
    document.querySelectorAll('[data-requires-ssh]').forEach((holder) => setHidden(holder, !anySsh));
    document.querySelectorAll('[data-setting-key="SSH_KEY"]').forEach((holder) => setHidden(holder, authMode() !== 'key'));
    document.querySelectorAll('[data-node-field]').forEach((holder) => {
      const index = Number(holder.dataset.nodeIndex);
      const node = state.config.nodes[index];
      if (!node) return;
      const key = holder.dataset.nodeField;
      setHidden(holder, !(nodeRules[key] ? nodeRules[key](node) : true));
    });
    document.querySelectorAll('tr.node-primary').forEach((row) => {
      const index = Number(row.dataset.nodeIndex);
      const node = state.config.nodes[index];
      if (!node) return;
      row.querySelectorAll('[data-node-primary-field]').forEach((cell) => {
        const key = cell.dataset.nodePrimaryField;
        setHidden(cell, !(nodeRules[key] ? nodeRules[key](node) : true));
      });
    });
    applyMasterRules();
    updateAdvancedBadge();
    syncButtons();
  }
  function updateAdvancedBadge() {
    const badge = $('advanced-badge');
    if (!badge || !state.config || !state.defaults) return;
    let changed = false;
    state.schema.settings.forEach((field) => {
      if (!BASIC_KEYS.includes(field.key) && JSON.stringify(state.config.settings[field.key]) !== JSON.stringify(state.defaults.settings[field.key])) changed = true;
    });
    badge.hidden = !changed;
    badge.textContent = changed ? '已修改自定义项' : '';
  }
  function primitive(value) {
    return typeof value === 'string' ? value : String(value === undefined || value === null ? '' : value);
  }
  function fieldControl(field, value, prefix, onChange) {
    const holder = el('div', null, 'field');
    holder.dataset.settingKey = prefix === 'setting' ? field.key : '';
    const rulesMap = activeRules();
    if (prefix === 'setting' && rulesMap[field.key]) holder.dataset.showWhen = JSON.stringify(rulesMap[field.key]);
    if (prefix === 'setting' && (field.key === 'SSH_AUTH_MODE' || field.key === 'SSH_KEY')) holder.dataset.requiresSsh = 'true';
    if (prefix.indexOf('node-') === 0) {
      holder.dataset.nodeField = field.key;
      holder.dataset.nodeIndex = prefix.slice(5);
    }
    const id = prefix + '-' + field.key;
    const label = el('label', field.key === 'ENDPOINT_ADDRESS' ? 'API VIP / 外部入口地址（APISERVER_VIP → ENDPOINT_ADDRESS）' : (field.label || field.key));
    label.htmlFor = id;
    holder.append(label);
    let input;
    if (prefix === 'setting' && (field.key === 'NTP_NODE' || field.key === 'NFS_NODE')) {
      input = document.createElement('select'); input.id = id; input.name = field.key;
      const empty = el('option', '未指定节点'); empty.value = ''; input.append(empty);
      const names = nodeNames();
      names.forEach((name) => { const option = el('option', name); option.value = name; input.append(option); });
      if (value && names.indexOf(value) < 0) { const option = el('option', value); option.value = value; input.append(option); }
      input.value = primitive(value);
      input.addEventListener('change', () => { onChange(input.value); applyVisibility(); });
      holder.append(input);
    } else if (field.key === 'roles' || field.type === 'array') {
      holder.classList.add('roles-field');
      const options = el('div', null, 'role-options');
      const allowed = field.enum || field.items_enum || [];
      allowed.forEach((role, index) => {
        const option = el('label', null, 'role-option');
        input = document.createElement('input'); input.type = 'checkbox'; input.id = id + '-' + index;
        input.value = String(role); input.checked = Array.isArray(value) && value.indexOf(role) >= 0;
        input.addEventListener('change', () => {
          onChange(Array.from(options.querySelectorAll('input:checked')).map((box) => box.value));
          applyVisibility();
        });
        const copy = el('span', null, 'role-copy');
        copy.append(el('span', optionLabel(field, role)));
        option.append(input, copy); options.append(option);
      });
      holder.append(options);
    } else if (field.type === 'boolean') {
      const line = el('div', null, 'checkbox-field');
      input = document.createElement('input'); input.type = 'checkbox'; input.id = id; input.checked = value === true;
      const boxLabel = el('label', input.checked ? '启用' : '关闭'); boxLabel.htmlFor = id;
      input.addEventListener('change', () => {
        boxLabel.textContent = input.checked ? '启用' : '关闭';
        onChange(input.checked); applyVisibility();
      });
      line.append(input, boxLabel); holder.append(line);
    } else {
      if (Array.isArray(field.enum)) {
        input = document.createElement('select');
        field.enum.forEach((choice) => {
          const option = el('option', optionLabel(field, choice)); option.value = String(choice); option.title = optionHelp(field, choice); input.append(option);
        });
      } else {
        input = document.createElement('input'); input.type = field.type === 'integer' ? 'number' : 'text';
        input.autocomplete = 'off'; input.spellcheck = false;
        if (field.type === 'integer') input.step = '1';
        if (field.minimum !== undefined) input.min = String(field.minimum);
        if (field.maximum !== undefined) input.max = String(field.maximum);
        if (field.max_length) input.maxLength = field.max_length;
      }
      input.id = id; input.name = field.key; input.value = primitive(value);
      holder.append(input);
      if (Array.isArray(field.enum)) {
        input.addEventListener('change', () => { onChange(input.value); applyVisibility(); });
      } else {
        input.addEventListener('input', () => { onChange(typeValue(input, field)); applyVisibility(); });
      }
    }
    if (field.help) holder.title = field.help;
    return holder;
  }
  function authControl() {
    const holder = el('div', null, 'field');
    holder.dataset.settingKey = 'SSH_AUTH_MODE';
    holder.dataset.requiresSsh = 'true';
    const label = el('label', 'SSH 认证方式'); label.htmlFor = 'setting-SSH_AUTH_MODE';
    holder.append(label);
    const select = document.createElement('select'); select.id = 'setting-SSH_AUTH_MODE'; select.name = 'SSH_AUTH_MODE';
    [['key', '密钥认证'], ['password', '密码认证']].forEach((pair) => { const option = el('option', pair[1]); option.value = pair[0]; select.append(option); });
    const current = authMode();
    select.value = current === 'password' ? 'password' : 'key';
    holder.append(select);
    const autoHolder = el('div', null, 'auto-key-field');
    const autoLabel = el('label', null, 'checkbox-field');
    const auto = document.createElement('input'); auto.type = 'checkbox'; auto.id = 'setting-SSH_AUTO_KEY';
    auto.checked = current !== 'key';
    const autoText = el('span', '自动在控制端生成默认 SSH 密钥对并分发至各节点（默认勾选）');
    autoLabel.append(auto, autoText); autoHolder.append(autoLabel);
    holder.append(autoHolder);
    const sync = () => {
      const mode = authMode();
      select.value = mode === 'password' ? 'password' : 'key';
      auto.checked = mode !== 'key';
      autoHolder.hidden = mode === 'password';
      auto.disabled = mode === 'password';
    };
    select.addEventListener('change', () => {
      state.config.settings.SSH_AUTH_MODE = select.value === 'password' ? 'password' : 'bootstrap';
      changed(); sync(); renderNodes(); applyVisibility();
    });
    auto.addEventListener('change', () => {
      state.config.settings.SSH_AUTH_MODE = auto.checked ? 'bootstrap' : 'key';
      changed(); sync(); renderNodes(); applyVisibility();
    });
    sync();
    return holder;
  }
  function basicFields() {
    if (!state.schema || !state.config) return;
    const area = $('basic-settings'); area.replaceChildren();
    const map = new Map(state.schema.settings.map((field) => [field.key, field]));
    const grid = el('div', null, 'field-grid');
    BASIC_KEYS.forEach((key) => {
      const field = map.get(key);
      if (!field) return;
      if (key === 'SSH_AUTH_MODE') { grid.append(authControl()); return; }
      grid.append(fieldControl(field, state.config.settings[key], 'setting', (value) => {
        state.config.settings[key] = value; changed();
        if (key === 'COMPONENTS') { normalizeHarborRoles(); renderSettings(); renderNodes(); renderCredentials(); }
        if (key === 'ENDPOINT_TYPE') applyMasterRules();
        if (key === 'REGISTRY_MODE') {
          if (value === 'external-harbor' && state.config.settings.COMPONENTS !== 'k8s') {
            state.config.settings.COMPONENTS = 'k8s';
          }
          const advanced = document.querySelector('#advanced-settings details');
          if (advanced) advanced.open = true;
          normalizeHarborRoles(); renderSettings(); renderNodes(); renderCredentials();
        }
        if (key === 'SSH_AUTH_MODE') renderNodes();
      }));
      if (key === 'COMPONENTS') {
        const holder = el('div', null, 'field');
        holder.append(el('label', 'Harbor 启用'));
        const line = el('div', null, 'checkbox-field');
        const box = document.createElement('input'); box.type = 'checkbox'; box.id = 'setting-HARBOR_ENABLED'; box.checked = harborEnabled();
        const copy = el('label', box.checked ? '启用 Harbor' : '不安装 Harbor'); copy.htmlFor = box.id;
        box.addEventListener('change', () => {
          const current = state.config.settings.COMPONENTS;
          state.config.settings.COMPONENTS = box.checked ? (current === 'harbor' ? 'harbor' : 'all') : 'k8s';
          changed(); normalizeHarborRoles(); renderSettings(); renderNodes(); renderCredentials();
        });
        line.append(box, copy); holder.append(line);
        holder.append(el('p', '关闭时 COMPONENTS=k8s；Harbor 字段与密码不提交。', 'field-help'));
        grid.append(holder);
      }
    });
    area.append(grid);
    const fixed = el('div', null, 'fixed-field');
    fixed.append(el('span', '网络插件'), el('strong', 'Calico（当前交付固定）'));
    fixed.append(el('p', '切换 CNI 需要先补 CLI/Artifact 支持。', 'field-help'));
    area.append(fixed);
  }
  function advancedFields() {
    if (!state.schema || !state.config) return;
    const host = $('advanced-settings'); host.replaceChildren();
    const details = el('details', null, 'config-group advanced-settings');
    const summary = document.createElement('summary');
    summary.append(el('span', '高级与安全选项'), el('span', '可选', 'group-count'));
    const badge = el('span', '', 'status-chip advanced-badge'); badge.id = 'advanced-badge'; badge.hidden = true;
    summary.append(badge);
    const body = el('div', null, 'advanced-groups');
    state.schema.groups.forEach((group) => {
      const fields = state.schema.settings.filter((field) => field.group === group.id && BASIC_KEYS.indexOf(field.key) < 0 && field.key !== 'ARTIFACT_SHA256');
      if (!fields.length) return;
      const block = el('section', null, 'advanced-block');
      block.append(el('h4', group.label || group.id));
      const grid = el('div', null, 'field-grid');
      fields.forEach((field) => grid.append(fieldControl(field, state.config.settings[field.key], 'setting', (value) => {
        state.config.settings[field.key] = value; changed();
        if (field.key === 'SSH_AUTH_MODE') renderNodes();
      })));
      block.append(grid); body.append(block);
    });
    details.append(summary, body); host.append(details);
  }
  function renderSettings() {
    basicFields(); advancedFields(); applyVisibility();
  }
  async function setConfigView(showEnv) {
    state.envView = Boolean(showEnv);
    $('config-form-view').hidden = state.envView;
    $('env-preview').hidden = !state.envView;
    $('view-form').classList.toggle('active', !state.envView);
    $('view-env').classList.toggle('active', state.envView);
    $('view-form').setAttribute('aria-pressed', String(!state.envView));
    $('view-env').setAttribute('aria-pressed', String(state.envView));
    if (!state.envView) return;
    $('env-preview-status').textContent = '正在生成…';
    try {
      const response = await api('/api/export', 'POST', {config: pruneConfig()});
      $('env-preview').textContent = response.text || '';
      $('env-preview-status').textContent = '已由服务端生成；不包含密码。';
    } catch (error) {
      $('env-preview').textContent = '';
      $('env-preview-status').textContent = '生成失败：' + error.message;
    }
  }
  function credentialSpec() {
    return state.schema && state.schema.credentials || {};
  }
  function nodeNeedsPassword(node) {
    return Boolean(node && node.connection === 'ssh' && authMode() === 'password');
  }
  function nodePasswordRequired(node) {
    return Boolean(node && node.connection === 'ssh' && authMode() === 'password');
  }
  function credentialValue(key) {
    if (key === 'harbor') return state.credentials.harbor || '';
    if (key.indexOf('node:') !== 0) return '';
    const node = state.config.nodes.find((row) => row.name === key.slice(5));
    return node ? (state.credentials.nodes.get(node) || '') : '';
  }
  function setCredentialValue(key, value) {
    if (key === 'harbor') { state.credentials.harbor = value; return; }
    if (key.indexOf('node:') !== 0) return;
    const node = state.config.nodes.find((row) => row.name === key.slice(5));
    if (node) state.credentials.nodes.set(node, value);
  }
  function collectCredentials() {
    const values = {};
    if (harborManaged() && harborRoleCount() > 0 && state.credentials.harbor) values.harbor = state.credentials.harbor;
    state.config.nodes.forEach((node) => {
      if (!nodeNeedsPassword(node) || !node.name) return;
      const value = state.credentials.nodes.get(node) || '';
      if (value) values['node:' + node.name] = value;
    });
    return values;
  }
  function credentialInput(key, label, required) {
    const holder = el('div', null, 'field');
    const id = 'credential-' + key.replace(/[^a-z0-9-]/gi, '-');
    const text = el('label', label + (required ? '（必填）' : '（可选）')); text.htmlFor = id;
    const input = document.createElement('input'); input.type = state.showPasswords ? 'text' : 'password';
    input.id = id; input.autocomplete = 'new-password'; input.spellcheck = false; input.required = required;
    input.value = credentialValue(key) || ''; input.dataset.credentialKey = key;
    input.addEventListener('input', () => setCredentialValue(key, input.value));
    holder.append(text, input); return holder;
  }
  function renderCredentials() {
    const button = $('toggle-password-visibility');
    if (!button) return;
    button.textContent = state.showPasswords ? '隐藏所有密码' : '显示所有密码';
    button.setAttribute('aria-pressed', String(state.showPasswords));
  }
  function harborPasswordControl(node) {
    if (!harborManaged() || registryMode() === 'external-harbor') return null;
    if (!Array.isArray(node.roles) || node.roles.indexOf('registry') < 0) return null;
    const input = document.createElement('input');
    input.type = state.showPasswords ? 'text' : 'password';
    input.className = 'matrix-harbor-password';
    input.autocomplete = 'new-password'; input.spellcheck = false;
    input.required = true; input.placeholder = 'Harbor admin 密码';
    input.value = state.credentials.harbor || '';
    input.addEventListener('input', () => {
      state.credentials.harbor = input.value;
      document.querySelectorAll('.matrix-harbor-password').forEach((item) => {
        if (item !== input) item.value = input.value;
      });
    });
    return input;
  }
  function matrixInput(node, key, index, type, placeholder) {
    const input = document.createElement('input');
    input.type = type || 'text'; input.value = primitive(node[key]); input.autocomplete = 'off'; input.spellcheck = false;
    input.placeholder = placeholder || ''; input.dataset.nodePrimaryFieldInput = key;
    input.addEventListener('input', () => {
      node[key] = type === 'number' ? (input.value === '' ? '' : Number(input.value)) : input.value;
      if (key === 'name') refreshNodeSelects();
      changed(); applyVisibility();
    });
    return input;
  }
  function matrixCell(content, field, className) {
    const cell = el('td', null, className || '');
    if (field) cell.dataset.nodePrimaryField = field;
    if (content) cell.append(content);
    return cell;
  }
  function roleLabels() {
    return {control_plane: 'Master', worker: 'Worker', etcd: 'Etcd(同机)', registry: 'Harbor', nfs: 'NFS', ntp: 'NTP'};
  }
  function roleControl(node) {
    const holder = el('div', null, 'role-options');
    const labels = roleLabels();
    const available = ['control_plane', 'worker', 'etcd', 'registry', 'nfs', 'ntp'];
    const harborDisabled = !harborManaged() || registryMode() === 'external-harbor';
    const harborSingular = harborManaged() && registryMode() === 'harbor';
    available.forEach((role) => {
      const label = el('label', null, 'role-option');
      const box = document.createElement('input');
      box.type = role === 'registry' && harborSingular ? 'radio' : 'checkbox';
      if (box.type === 'radio') box.name = 'harbor-registry';
      box.value = role;
      box.checked = Array.isArray(node.roles) && node.roles.indexOf(role) >= 0;
      if (role === 'registry' && harborDisabled) { box.disabled = true; box.checked = false; }
      box.addEventListener('change', () => {
        if (role === 'registry') {
          if (harborSingular) {
            state.config.nodes.forEach((item) => { item.roles = (item.roles || []).filter((value) => value !== 'registry'); });
            node.roles = (node.roles || []).concat('registry');
          } else {
            node.roles = Array.from(holder.querySelectorAll('input:checked')).map((item) => item.value);
          }
          changed(); renderNodes(); return;
        }
        if (role === 'control_plane' || role === 'etcd') {
          node.roles = logic.syncMasterEtcdRoles(node.roles, role, box.checked);
          changed(); renderNodes(); return;
        }
        node.roles = Array.from(holder.querySelectorAll('input:checked')).map((item) => item.value);
        changed(); applyMasterRules(); applyHarborRules(); syncButtons();
      });
      label.append(box, el('span', labels[role] || role)); holder.append(label);
    });
    return holder;
  }
  function nodePasswordControl(node) {
    if (!nodeNeedsPassword(node)) return el('span', 'local / key 不需要密码', 'matrix-note');
    const input = document.createElement('input'); input.type = state.showPasswords ? 'text' : 'password';
    input.autocomplete = 'new-password'; input.spellcheck = false;
    input.placeholder = nodePasswordRequired(node) ? '必填 SSH 密码' : '可选 SSH 密码';
    input.value = state.credentials.nodes.get(node) || '';
    input.addEventListener('input', () => state.credentials.nodes.set(node, input.value));
    return input;
  }
  function storagePreview(node) {
    const box = el('div', null, 'derived-links');
    const settings = state.config.settings;
    const links = logic.storageLinks(node.data_path, node.data_mode, {
      localStorage: settings.LOCAL_STORAGE === true,
      localPath: settings.LOCAL_PATH,
      nfsMode: settings.NFS_MODE,
      nfsPath: settings.NFS_PATH
    });
    if (!links.length) {
      box.append(el('span', 'native：使用系统原生 /var/lib，不创建组件软链接；数据根目录只作声明/台账。etcd 始终使用系统盘 /var/lib/etcd。启用本地存储/NFS 时仍会创建 LOCAL_PATH/NFS_PATH（默认 /data/local-pv、/data/nfs）。', 'native-storage-note'));
      return box;
    }
    links.forEach((link) => {
      box.append(el('span', link.name + ' → ' + link.source), el('span', '⇒ ' + link.target, 'arrow'));
    });
    box.append(el('span', 'etcd → /var/lib/etcd（系统盘，不迁移）', 'native-storage-note'));
    return box;
  }
  function renderNodes() {
    const list = $('nodes-list'); if (!list || !state.config) return;
    normalizeHarborRoles();
    list.replaceChildren();
    if (!state.config.nodes.length) {
      list.append(el('p', '尚未添加节点。', 'empty-state'));
      $('add-node').disabled = state.busy;
      refreshNodeSelects(); applyVisibility(); renderCredentials(); return;
    }
    const wrap = el('div', null, 'node-matrix-wrap');
    const table = el('table', null, 'node-matrix');
    const head = document.createElement('thead'); const headRow = document.createElement('tr');
    ['主机名', '连接 IPv4', '内网 IPv4', '连接方式', 'SSH 用户', '端口', 'SSH 密码', 'Harbor 密码', '角色', '操作'].forEach((label, position) => {
      const cell = el('th', label);
      if (position === 7) { cell.id = 'harbor-password-header'; cell.hidden = !harborManaged() || registryMode() === 'external-harbor'; }
      headRow.append(cell);
    });
    head.append(headRow); table.append(head);
    const body = document.createElement('tbody');
    state.config.nodes.forEach((node, index) => {
      const row = document.createElement('tr'); row.className = 'node-primary'; row.dataset.nodeIndex = String(index);
      row.append(matrixCell(matrixInput(node, 'name', index, 'text', 'nodeN'), null, 'matrix-name'));
      row.append(matrixCell(matrixInput(node, 'address', index, 'text', '192.0.2.10'), null, 'matrix-address'));
      row.append(matrixCell(matrixInput(node, 'internal_address', index, 'text', '192.0.2.10'), null, 'matrix-ip'));
      const connection = document.createElement('select');
      [['ssh', 'SSH'], ['local', 'local']].forEach((pair) => { const option = el('option', pair[1]); option.value = pair[0]; connection.append(option); });
      connection.value = node.connection || 'ssh';
      connection.addEventListener('change', () => { node.connection = connection.value; changed(); renderNodes(); });
      row.append(matrixCell(connection, null, 'matrix-connection'));
      const userInput = matrixInput(node, 'user', index, 'text', 'root');
      row.append(matrixCell(userInput, 'user', 'matrix-user'));
      const portInput = matrixInput(node, 'port', index, 'number', '22');
      row.append(matrixCell(portInput, 'port', 'matrix-port'));
      const passwordCell = matrixCell(nodePasswordControl(node), 'password', 'matrix-password node-credential'); passwordCell.dataset.nodeCredential = 'true';
      row.append(passwordCell);
      const harborCell = matrixCell(harborPasswordControl(node), 'harbor-password', 'matrix-harbor');
      harborCell.hidden = !harborManaged() || registryMode() === 'external-harbor' || !Array.isArray(node.roles) || node.roles.indexOf('registry') < 0;
      row.append(harborCell);
      row.append(matrixCell(roleControl(node), null, 'matrix-roles'));
      const actions = el('div', null, 'matrix-actions');
      const expandButton = el('button', '展开', 'button quiet compact node-expand'); expandButton.type = 'button'; expandButton.setAttribute('aria-expanded', 'false');
      const cloneButton = el('button', '克隆行', 'button secondary compact node-clone'); cloneButton.type = 'button';
      cloneButton.addEventListener('click', () => {
        const copy = clone(node);
        copy.name = logic.nextNodeName(node.name || 'node', nodeNames());
        const used = new Set(state.config.nodes.map((item) => item.address).filter(Boolean));
        let address = logic.nextIPv4(node.address);
        while (address && used.has(address)) address = logic.nextIPv4(address);
        copy.address = address || '';
        const usedInternal = new Set(state.config.nodes.map((item) => item.internal_address).filter(Boolean));
        let internal = logic.nextIPv4(node.internal_address || node.address);
        while (internal && usedInternal.has(internal)) internal = logic.nextIPv4(internal);
        copy.internal_address = internal || copy.address;
        copy.password_env = 'NODE' + (state.config.nodes.length + 1) + '_PASSWORD';
        state.config.nodes.splice(index + 1, 0, copy);
        const password = state.credentials.nodes.get(node);
        if (password) state.credentials.nodes.set(copy, password);
        changed(); renderNodes();
      });
      const remove = el('button', '删除', 'button danger compact'); remove.type = 'button';
      remove.addEventListener('click', () => {
        if (!window.confirm('移除当前草稿节点“' + (node.name || String(index + 1)) + '”？不会操作实际节点。')) return;
        state.credentials.nodes.delete(node); state.config.nodes.splice(index, 1); changed(); renderNodes();
      });
      actions.append(expandButton, cloneButton, remove); row.append(matrixCell(actions, null, 'matrix-actions'));
      body.append(row);
      const detailRow = document.createElement('tr'); detailRow.className = 'node-detail';
      const detailCell = document.createElement('td'); detailCell.colSpan = 10;
      const details = document.createElement('details');
      details.append(el('summary', '节点扩展参数'));
      const grid = el('div', null, 'field-grid');
      state.schema.node_fields.forEach((field) => {
        if (['name', 'address', 'user', 'port', 'connection', 'roles', 'password_env'].indexOf(field.key) >= 0) return;
        const holder = fieldControl(field, node[field.key], 'node-' + index, (value) => {
          node[field.key] = value; changed();
          if (field.key === 'data_mode') { renderNodes(); return; }
          applyVisibility();
        });
        if (field.key === 'data_path') {
          let live = storagePreview(node);
          holder.append(live);
          const pathInput = holder.querySelector('input');
          if (pathInput) pathInput.addEventListener('input', () => { const next = storagePreview(node); live.replaceWith(next); live = next; });
        }
        grid.append(holder);
      });
      details.append(grid); detailCell.append(details); detailRow.append(detailCell); body.append(detailRow);
      expandButton.addEventListener('click', () => {
        details.open = !details.open;
        expandButton.textContent = details.open ? '收起' : '展开';
        expandButton.setAttribute('aria-expanded', String(details.open));
      });
    });
    table.append(body); wrap.append(table); list.append(wrap);
    $('add-node').disabled = state.busy || state.config.nodes.length >= 32;
    refreshNodeSelects(); applyVisibility(); renderCredentials();
  }
  function refreshNodeSelects() {
    if (!state.config) return;
    const names = nodeNames();
    document.querySelectorAll('[data-setting-key="NTP_NODE"], [data-setting-key="NFS_NODE"]').forEach((holder) => {
      const select = holder.querySelector('select'); if (!select) return;
      const key = holder.dataset.settingKey;
      const current = state.config.settings[key] || '';
      select.replaceChildren();
      const empty = el('option', '未指定节点'); empty.value = ''; select.append(empty);
      names.forEach((name) => { const option = el('option', name); option.value = name; select.append(option); });
      if (current && names.indexOf(current) < 0) { const option = el('option', current); option.value = current; select.append(option); }
      select.value = current;
    });
  }
  function pruneConfig() {
    const config = logic.pruneConfig(state.config, activeRules(), authMode());
    delete config.settings.ARTIFACT_SHA256;
    if (config.settings.ENDPOINT_TYPE === 'local' || config.settings.ENDPOINT_TYPE === 'haproxy') {
      config.settings.ENDPOINT_ADDRESS = '';
    }
    if (config.settings.SSH_AUTH_MODE !== 'key') delete config.settings.SSH_KEY;
    if (config.settings.SSH_AUTH_MODE === 'password') {
      config.nodes.forEach((node, index) => { if (node.connection === 'ssh') node.password_env = 'NODE' + (index + 1) + '_PASSWORD'; });
    }
    if (!harborManaged() || config.settings.REGISTRY_MODE === 'external-harbor') {
      config.nodes.forEach((node) => { node.roles = (node.roles || []).filter((role) => role !== 'registry'); });
    } else if (config.settings.REGISTRY_MODE === 'harbor') {
      let found = false;
      config.nodes.forEach((node) => {
        if ((node.roles || []).indexOf('registry') >= 0) {
          if (found) node.roles = node.roles.filter((role) => role !== 'registry');
          else found = true;
        }
      });
    }
    return config;
  }
  function loadConfig(config) {
    state.generation += 1;
    state.config = clone(config);
    const anyExplicitEtcd = (state.config.nodes || []).some((node) => Array.isArray(node.roles) && node.roles.indexOf('etcd') >= 0);
    if (!anyExplicitEtcd) {
      (state.config.nodes || []).forEach((node) => {
        if (Array.isArray(node.roles) && node.roles.indexOf('control_plane') >= 0 && node.roles.indexOf('etcd') < 0) {
          node.roles.push('etcd');
        }
      });
    }
    if (!state.config.settings.ARTIFACT_FILE && suggestionPath()) state.config.settings.ARTIFACT_FILE = suggestionPath();
    state.dirty = false;
    state.credentials = {harbor: '', nodes: new Map()};
    clearProbeResults();
    renderSettings(); renderNodes(); renderCredentials(); clearResults();
  }
  function changed() {
    state.generation += 1; state.dirty = true;
  }
  function clearProbeResults() {
    const host = $('probe-results');
    if (host) { host.hidden = true; host.replaceChildren(); }
  }
  function renderProbeResults(response) {
    const host = $('probe-results');
    if (!host) return;
    host.replaceChildren();
    const nodes = response && response.nodes || [];
    if (!nodes.length) { host.hidden = true; return; }
    const table = el('table', null, 'probe-table');
    const head = document.createElement('thead');
    const hrow = document.createElement('tr');
    ['节点', 'SSH / 接入状态', '实测主机名', '实测架构', '实测 OS 依赖包', '冲突 / 详情'].forEach((label) => hrow.append(el('th', label)));
    head.append(hrow); table.append(head);
    const body = document.createElement('tbody');
    nodes.forEach((item) => {
      const row = document.createElement('tr');
      row.append(el('td', item.name + (item.ip ? ' (' + item.ip + ')' : '')));
      const statusText = item.status === 'passed' ? '通过' : (item.status === 'collected_with_conflicts' ? '连通（有冲突）' : '失败');
      row.append(el('td', statusText));
      row.append(el('td', item.hostname || '未采集'));
      row.append(el('td', item.arch || '未识别'));
      row.append(el('td', item.os_package || '未映射'));
      const detail = (item.conflicts && item.conflicts.length) ? item.conflicts.join('；') : (item.error_summary || '无');
      row.append(el('td', detail));
      body.append(row);
    });
    table.append(body); host.append(table); host.hidden = false;
  }
  async function probeNodes() {
    if (!state.capability) { notice('执行器未启用，无法在线探测节点。', 'error'); return; }
    if (!state.config || !state.config.nodes.length) { notice('请先添加至少一个节点。', 'error'); return; }
    notice(''); setBusy(true);
    try {
      const response = await api('/api/execution/probe-nodes', 'POST', {
        config: pruneConfig(), credentials: collectCredentials()
      }, 120000);
      renderProbeResults(response);
      let synced = 0;
      (response.nodes || []).forEach((probed) => {
        const target = state.config.nodes.find((row) => row.name === probed.name);
        if (!target) return;
        if ((probed.arch === 'amd64' || probed.arch === 'arm64') && target.arch !== probed.arch) {
          target.arch = probed.arch; synced += 1;
        }
        if (probed.os_package && ['ubuntu-24.04-debs', 'ubuntu-22.04-debs', 'kylin-v10SP3-2403-rpms'].includes(probed.os_package) && target.os !== probed.os_package) {
          target.os = probed.os_package; synced += 1;
        }
      });
      if (synced > 0) { changed(); renderNodes(); }
      const failedCount = (response.nodes || []).filter((n) => n.status === 'failed').length;
      const conflictCount = (response.nodes || []).filter((n) => n.conflicts && n.conflicts.length).length;
      if (response.ok && !failedCount && !conflictCount) {
        notice('全部节点探测通过' + (synced > 0 ? '，并已按实测结果自动回填节点架构或系统包。' : '。'), 'success');
      } else {
        notice('节点探测完成：' + failedCount + ' 个节点接入失败，' + conflictCount + ' 个节点存在冲突' + (synced > 0 ? '（已自动同步实测架构/系统包）。' : '；请展开上方表格查看。'), 'error');
      }
    } catch (error) {
      notice('节点探测失败：' + error.message, 'error');
    } finally { setBusy(false); }
  }
  function clearResults() {
    $('result-status').textContent = '尚未校验'; $('result-status').className = 'status-chip neutral';
    $('results-content').replaceChildren(el('p', '填写第 1 步后点击“校验配置”。', 'empty-state'));
    $('next-step-3').disabled = true;
  }
  function applyPreset(kind, notify) {
    const base = clone(state.defaults);
    const artifact = state.suggestions && state.suggestions.artifact_file ? state.suggestions.artifact_file.value : '';
    if (artifact) base.settings.ARTIFACT_FILE = artifact;
    base.settings.ARTIFACT_SHA256 = '';
    base.settings.DEPS_MODE = 'iso';
    base.settings.LOCAL_STORAGE = true;
    base.settings.NTP_MODE = 'node'; base.settings.NTP_ALLOW_LOCAL = true;
    base.settings.NFS_MODE = 'new'; base.settings.NFS_PATH = '/data/nfs';
    base.settings.REGISTRY_MODE = 'harbor';
    base.settings.SSH_AUTH_MODE = 'bootstrap';
    base.settings.SSH_KEY = '/root/.ssh/rise_deploy';
    if (kind === 'single') {
      base.settings.CLUSTER_NAME = 'rise-single'; base.settings.COMPONENTS = 'all';
      base.settings.ENDPOINT_TYPE = 'local'; base.settings.ENDPOINT_ADDRESS = '';
      base.settings.K8S_DOMAIN = 'k8s.single.local'; base.settings.HARBOR_DOMAIN = 'harbor.single.local';
      const node = base.nodes[0];
      node.name = 'node1'; node.address = '192.0.2.10'; node.internal_address = '192.0.2.10';
      node.connection = 'local'; node.roles = ['control_plane', 'worker', 'etcd', 'registry'];
      node.data_mode = 'native'; node.password_env = ''; node.device = '';
      base.settings.NTP_NODE = 'node1'; base.settings.NFS_NODE = 'node1';
      base.nodes = [node];
    } else {
      base.settings.CLUSTER_NAME = 'rise-ha'; base.settings.COMPONENTS = 'all';
      base.settings.ENDPOINT_TYPE = 'kube-vip'; base.settings.ENDPOINT_ADDRESS = '192.0.2.100';
      base.settings.K8S_DOMAIN = 'k8s.ha.local'; base.settings.HARBOR_DOMAIN = 'harbor.ha.local';
      base.settings.NTP_NODE = base.nodes[0].name; base.settings.NFS_NODE = base.nodes[0].name;
    }
    state.config = base;
    state.credentials = {harbor: '', nodes: new Map()};
    state.dirty = false;
    clearProbeResults();
    renderSettings(); renderNodes(); renderCredentials(); clearResults();
    if (notify !== false) notice('已填充' + (kind === 'single' ? '单机模板' : '三节点 HA 模板') + '；请核对 IP、域名、密码和归档路径。', 'success');
    else notice('');
  }
  async function exportEnv() {
    try {
      const response = await api('/api/export', 'POST', {config: pruneConfig()});
      const blob = new Blob([response.text || ''], {type: 'text/plain;charset=utf-8'});
      const url = URL.createObjectURL(blob); const link = document.createElement('a');
      link.href = url; link.download = response.filename || 'cluster-vars.env';
      document.body.append(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      notice('已导出不含密码的 .env；请按现场配置审阅后交给 CLI。', 'success');
    } catch (error) { notice('导出失败：' + error.message, 'error'); }
  }
  async function importEnv(file) {
    if (!file) return;
    if (file.size > 128 * 1024) { notice('导入文件超过 128 KiB。', 'error'); return; }
    try {
      const text = await file.text();
      const response = await api('/api/import', 'POST', {text: text});
      loadConfig(response.config);
      notice('已导入 .env；密码不会从文件导入，请重新填写。', 'success');
    } catch (error) { notice('导入失败：' + error.message, 'error'); }
    finally { const input = $('import-env-file'); if (input) input.value = ''; }
  }
  async function validateCurrent(kind) {
    if (!masterValid()) { renderMasterStepError(); notice(masterTopology().reason || 'Master/Etcd 节点数量必须为 1、3、5… 正奇数。', 'error'); return; }
    if (!harborRoleValid()) { applyHarborRules(); renderHarborStepError(); notice('Harbor 节点数量与仓库模式不匹配。', 'error'); return; }
    setBusy(true);
    try {
      const response = await api(kind === 'plan' ? '/api/plan' : '/api/validate', 'POST', {config: pruneConfig()});
      renderResult(response, kind === 'plan');
      if (response.valid) $('next-step-3').disabled = false;
    } catch (error) { notice(error.message, 'error'); }
    finally { setBusy(false); }
  }
  function renderResult(response, isPlan) {
    const area = $('results-content'); area.replaceChildren();
    if (!response || !response.valid) {
      $('result-status').textContent = '未通过'; $('result-status').className = 'status-chip invalid';
      const list = el('ul', null, 'result-errors');
      (response && response.errors || ['配置未通过校验']).forEach((error) => list.append(el('li', typeof error === 'string' ? error : JSON.stringify(error))));
      area.append(list); return;
    }
    $('result-status').textContent = isPlan ? '计划已生成' : '校验通过';
    $('result-status').className = 'status-chip valid';
    const result = response.result || {};
    area.append(el('p', isPlan ? '只读计划已生成；执行仍由第 3 步完成。' : '参数校验通过；未连接节点。', 'result-intro'));
    const summary = el('div', null, 'plan-summary');
    [['集群', result.config && result.config.cluster_name], ['Kubernetes', result.config && result.config.kubernetes_version], ['节点', result.config && (result.config.declared_nodes || []).length], ['阶段', (result.steps || []).length]].forEach((pair) => {
      const tile = el('div', null, 'summary-tile'); tile.append(el('span', pair[0]), el('strong', pair[1] === undefined ? '—' : pair[1])); summary.append(tile);
    });
    area.append(summary);
    if (isPlan) {
      const steps = el('ol', null, 'plan-steps');
      (result.steps || []).forEach((step) => steps.append(el('li', step)));
      area.append(el('h4', '拟执行阶段'), steps);
      if (result.blockers && result.blockers.length) area.append(el('h4', '已知阻塞'), el('p', result.blockers.join('、'), 'result-errors'));
    }
  }
  async function refreshExecution() {
    state.executorLoading = true; syncButtons();
    try {
      const capability = await api('/api/execution');
      state.capability = capability && capability.enabled ? capability : null;
      $('execution-mode').textContent = state.capability ? '执行器就绪' : '配置模式';
      $('execution-capability').textContent = state.capability
        ? '执行器已就绪：' + state.capability.executor.user + ' @ ' + state.capability.executor.host + '。'
        : '执行器未启用；可填写并导出 .env，但第 3 步不能直接安装。';
      if (state.capability) {
        await refreshJobs();
        await refreshClusters();
      } else {
        state.clusters = []; state.expandTarget = null; renderClusters();
      }
    } catch (error) {
      state.capability = null; $('execution-mode').textContent = '执行能力未确认'; $('execution-capability').textContent = error.message;
    } finally { state.executorLoading = false; syncButtons(); }
  }
  async function refreshClusters() {
    if (!state.capability) return;
    try {
      const response = await api('/api/execution/clusters');
      state.clusters = response.clusters || [];
      if (state.expandTarget) {
        state.expandTarget = state.clusters.find((c) => c.state_dir === state.expandTarget.state_dir) || null;
      }
      renderClusters();
    } catch (error) {
      if ($('clusters-status')) $('clusters-status').textContent = '读取受管集群失败：' + error.message;
    } finally { syncButtons(); }
  }
  function selectExpandCluster(cluster) {
    state.expandTarget = cluster;
    const section = $('worker-expand-section');
    if (!section) return;
    section.hidden = !cluster;
    if (!cluster) { syncButtons(); return; }
    $('expand-target-label').textContent = '目标：' + cluster.cluster_name + '（' + cluster.kube_version + ' · ' + cluster.state_dir + '）';
    const existingNames = (cluster.nodes || []).map((n) => n.name);
    const nameInput = $('expand-node-name');
    if (nameInput && !nameInput.value.trim()) nameInput.value = logic.nextNodeName('worker', existingNames);
    const lastIp = (cluster.nodes || []).slice(-1)[0];
    const suggestedIp = lastIp ? logic.nextIPv4(lastIp.internal_address || lastIp.address) : '';
    if ($('expand-node-address') && !$('expand-node-address').value.trim() && suggestedIp) $('expand-node-address').value = suggestedIp;
    if ($('expand-node-internal') && !$('expand-node-internal').value.trim() && suggestedIp) $('expand-node-internal').value = suggestedIp;
    const needHarbor = cluster.components !== 'k8s' && cluster.registry_mode !== 'external-harbor';
    if ($('expand-harbor-pw-holder')) $('expand-harbor-pw-holder').hidden = !needHarbor;
    const sshPwInput = $('expand-node-ssh-password');
    if (sshPwInput) sshPwInput.placeholder = cluster.ssh_auth_mode === 'password' ? '必填 SSH 密码' : '已配置免密可留空';
    syncButtons();
  }
  function renderClusters() {
    const list = $('clusters-list');
    const statusLabel = $('clusters-status');
    if (!list) return;
    list.replaceChildren();
    if (!state.capability) {
      if (statusLabel) statusLabel.textContent = '连接执行器后可查看已有集群与提交 Worker 扩容。';
      if ($('worker-expand-section')) $('worker-expand-section').hidden = true;
      return;
    }
    if (!state.clusters.length) {
      if (statusLabel) statusLabel.textContent = '尚未发现已部署的受管集群状态目录。';
      list.append(el('p', '暂无受管集群记录。', 'empty-state'));
      if ($('worker-expand-section')) $('worker-expand-section').hidden = true;
      return;
    }
    if (statusLabel) statusLabel.textContent = '共发现 ' + state.clusters.length + ' 个受管集群（' + state.clusters.filter((c) => c.expandable).length + ' 个可扩容）。';
    const activeJob = state.job && ['queued', 'running', 'stop_requested'].indexOf(state.job.state) >= 0;
    state.clusters.forEach((cluster) => {
      const card = el('div', null, 'cluster-card');
      const head = el('div', null, 'cluster-card-head');
      const title = el('strong', cluster.cluster_name + ' · ' + cluster.kube_version + ' (' + cluster.endpoint_type + ')');
      const badge = el('span', cluster.pending_expansion ? '存在未完成扩容' : ('回执：' + cluster.deployment_status), 'status-chip ' + (cluster.expandable ? 'valid' : 'neutral'));
      head.append(title, badge);
      const nodesSummary = (cluster.nodes || []).map((n) => n.name + '[' + (n.roles || []).join(',') + ']').join('，');
      const wfSummary = Object.keys(cluster.workflow_stages || {}).sort().map((k) => k + ':' + cluster.workflow_stages[k]).join(' · ');
      const meta = el('div', '范围：' + cluster.components + ' | 仓库：' + cluster.registry_mode + ' | 节点：' + nodesSummary, 'cluster-meta');
      const wfLine = el('div', '阶段快照：' + (wfSummary || '无'), 'cluster-meta');
      const action = el('button', '扩容 Worker', 'button secondary compact');
      action.type = 'button';
      action.disabled = !cluster.expandable || activeJob || state.busy;
      action.addEventListener('click', () => selectExpandCluster(cluster));
      head.append(action);
      card.append(head, meta, wfLine);
      list.append(card);
    });
    if (state.expandTarget) selectExpandCluster(state.expandTarget);
  }
  async function submitExpandWorkers() {
    if (!state.capability || !state.expandTarget) { notice('请先选择一个可扩容的受管集群。', 'error'); return; }
    const name = ($('expand-node-name').value || '').trim();
    const address = ($('expand-node-address').value || '').trim();
    const internal = ($('expand-node-internal').value || '').trim() || address;
    const user = ($('expand-node-user').value || '').trim() || 'root';
    const port = Number($('expand-node-port').value || 22);
    const arch = $('expand-node-arch').value;
    const osPkg = $('expand-node-os').value;
    const dataPath = ($('expand-node-data').value || '').trim() || '/data';
    const dataMode = $('expand-node-data-mode').value;
    const sshPw = $('expand-node-ssh-password').value || '';
    const harborPw = $('expand-node-harbor-password').value || '';
    if (!name || !address) { notice('请填写新 Worker 节点名称和 IPv4 地址。', 'error'); return; }
    const credentials = {};
    if (sshPw) credentials['node:' + name] = sshPw;
    if (state.expandTarget.components !== 'k8s' && state.expandTarget.registry_mode !== 'external-harbor') {
      if (!harborPw) { notice('受管 Harbor 集群扩容必须填写原集群 Harbor admin 密码。', 'error'); return; }
      credentials.harbor = harborPw;
    }
    const newNode = {
      name: name, address: address, internal_address: internal, user: user, port: port,
      arch: arch, os: osPkg, roles: ['worker'], connection: 'ssh',
      data_path: dataPath, data_mode: dataMode, device: '', password_env: ''
    };
    setBusy(true); $('expand-status').textContent = '正在提交 Worker 扩容任务…';
    try {
      const job = await api('/api/execution/expand-workers', 'POST', {
        request_id: crypto.randomUUID(),
        cluster_name: state.expandTarget.cluster_name,
        state_dir: state.expandTarget.state_dir,
        new_nodes: [newNode],
        credentials: credentials,
        debug: false
      });
      $('expand-node-ssh-password').value = '';
      $('expand-node-harbor-password').value = '';
      state.job = job; state.offset = 0; state.log = '';
      await refreshJobs(); await refreshClusters();
      notice('Worker 扩容任务已提交；请在上方任务日志查看实时进度与台账同步。', 'success');
    } catch (error) {
      notice('提交 Worker 扩容失败：' + error.message, 'error');
    } finally { $('expand-status').textContent = ''; setBusy(false); }
  }
  function syncButtons() {
    const executable = Boolean(state.capability && !state.capability.recovery_required && masterValid() && harborRoleValid());
    const activeJob = state.job && ['queued', 'running', 'stop_requested'].indexOf(state.job.state) >= 0;
    if ($('probe-nodes')) $('probe-nodes').disabled = state.busy || !state.capability || !state.config || !state.config.nodes.length;
    if ($('refresh-clusters')) $('refresh-clusters').disabled = state.busy || !state.capability;
    if ($('submit-expand-workers')) $('submit-expand-workers').disabled = state.busy || !state.capability || activeJob || !state.expandTarget || !state.expandTarget.expandable || Boolean(state.capability && state.capability.recovery_required);
    if ($('next-step-2')) $('next-step-2').disabled = state.busy || !masterValid() || !harborRoleValid();
    if ($('next-step-3')) $('next-step-3').disabled = state.busy || !masterValid() || !harborRoleValid();
    if ($('start-deploy-direct')) $('start-deploy-direct').disabled = state.busy || !executable || activeJob;
    if ($('download-ledger')) $('download-ledger').disabled = state.busy || !state.capability;

    if ($('add-node')) $('add-node').disabled = state.busy || !state.config || state.config.nodes.length >= 32;
    if ($('preset-single')) $('preset-single').disabled = state.busy;
    if ($('preset-ha')) $('preset-ha').disabled = state.busy;
    if ($('use-package-artifact')) $('use-package-artifact').disabled = state.busy || !suggestionPath();
    const components = state.config && state.config.settings ? state.config.settings.COMPONENTS : 'all';
    if ($('stage-prepare')) $('stage-prepare').disabled = state.busy || !executable || activeJob;
    if ($('stage-harbor')) $('stage-harbor').disabled = state.busy || !executable || activeJob || !harborEnabled() || registryMode() === 'external-harbor';
    if ($('stage-k8s')) $('stage-k8s').disabled = state.busy || !executable || activeJob || components === 'harbor';
    const stoppable = state.job && ['queued', 'running'].indexOf(state.job.state) >= 0;
    if ($('stop-current-job')) $('stop-current-job').disabled = state.busy || !executable || !stoppable;
  }
  function suggestionPath() {
    const item = state.suggestions && state.suggestions.artifact_file;
    return item && typeof item.value === 'string' ? item.value : '';
  }
  async function startDeployDirect() {
    return submitStage('all');
  }
  async function startStage(stage) {
    return submitStage(stage);
  }
  async function submitStage(stage) {
    if (!state.capability) { notice('执行器未启用，不能直接安装。', 'error'); return; }
    const labels = {all: '一键全量安装', prepare: '前置检查与免密', harbor: '部署仓库 (Harbor)', k8s: '部署集群 (K8s)'};
    if (stage === 'harbor' && !harborEnabled()) { notice('Harbor 未启用，不能执行 Harbor 阶段。', 'error'); return; }
    if (stage === 'k8s' && state.config.settings.COMPONENTS === 'harbor') { notice('组件范围仅为 Harbor，不能执行 K8s 阶段。', 'error'); return; }
    const config = pruneConfig();
    setBusy(true); $('direct-status').textContent = '正在校验配置（' + labels[stage] + '）…';
    try {
      const validation = await api('/api/validate', 'POST', {config: config});
      if (!validation || !validation.valid) throw new Error('配置校验未通过，请先回到第 2 步修正。');
      $('direct-status').textContent = '正在生成执行摘要…';
      const preview = await api('/api/jobs/preview', 'POST', {config: config, stage: stage});
      const allCredentials = collectCredentials();
      const requiredKeys = new Set((preview.required_credentials || []).map((item) => item.key));
      const credentials = {};
      Object.keys(allCredentials).forEach((key) => { if (requiredKeys.has(key)) credentials[key] = allCredentials[key]; });
      const missing = (preview.required_credentials || []).filter((item) => item.required && !credentials[item.key]);
      if (missing.length) {
        goStep(1);
        throw new Error('缺少凭据：' + missing.map((item) => item.label).join('、') + '；请填写并保存后重试。');
      }
      $('direct-status').textContent = '正在提交后台任务…';
      const requestId = crypto.randomUUID();
      const job = await api('/api/jobs', 'POST', {request_id: requestId, plan_id: preview.plan_id,
        config_sha256: preview.config_sha256, acknowledged: true, credentials: credentials, debug: false, stage: stage});
      state.job = job; state.offset = 0; state.log = ''; goStep(3); await refreshJobs();
      notice(labels[stage] + '任务已提交；关闭页面不会停止任务。', 'success');
    } catch (error) {
      notice('安装提交失败：' + error.message, 'error');
    } finally {
      $('direct-status').textContent = ''; setBusy(false);
    }
  }
  async function stopCurrentJob() {
    if (!state.job || ['queued', 'running'].indexOf(state.job.state) < 0) return;
    try {
      await api('/api/jobs/' + encodeURIComponent(state.job.id) + '/stop', 'POST', {});
      notice('已在阶段边界请求停止；不会回滚已完成操作。', 'success');
      await refreshJobs();
    } catch (error) { notice('停止请求失败：' + error.message, 'error'); }
  }
  function renderStageProgress() {
    const labels = {prepare: '前置检查', harbor: 'Harbor', k8s: 'K8s'};
    const order = ['prepare', 'harbor', 'k8s'];
    const badges = {};
    document.querySelectorAll('[data-stage-badge]').forEach((badge) => { badges[badge.dataset.stageBadge] = badge; });
    const set = (stage, status, text) => {
      const badge = badges[stage]; if (!badge) return;
      badge.className = 'stage-badge ' + status; badge.textContent = labels[stage] + '：' + text;
    };
    order.forEach((stage) => set(stage, 'pending', '未开始'));
    if (!state.job) return;
    const requested = state.job.stage || 'all';
    const stateName = state.job.state;
    const active = ['queued', 'running', 'stop_requested'].indexOf(stateName) >= 0;
    const failed = ['failed', 'interrupted'].indexOf(stateName) >= 0;
    const stopped = stateName === 'stopped';
    const done = stateName === 'succeeded';
    if (requested === 'add-workers') {
      set('prepare', 'done', '复用原集群');
      set('harbor', 'done', '按需补推');
      if (done) set('k8s', 'done', '扩容完成');
      else if (failed) set('k8s', 'failed', '扩容失败');
      else if (stopped) set('k8s', 'stopped', '已停止');
      else if (active) set('k8s', 'running', '扩容中');
      return;
    }
    if (requested === 'all') {
      if (done) order.forEach((stage) => set(stage, 'done', '已完成'));
      else if (failed) order.forEach((stage) => set(stage, 'failed', '失败'));
      else if (stopped) order.forEach((stage) => set(stage, 'stopped', '已停止'));
      else if (active) order.forEach((stage) => set(stage, 'running', '运行中'));
      return;
    }
    const index = order.indexOf(requested);
    order.forEach((stage, position) => {
      if (position < index) set(stage, 'done', '已完成');
      else if (position > index) set(stage, 'pending', '未开始');
      else if (done) set(stage, 'done', '已完成');
      else if (failed) set(stage, 'failed', '失败');
      else if (stopped) set(stage, 'stopped', '已停止');
      else if (active) set(stage, 'running', '运行中');
    });
  }
  async function refreshJobs() {
    if (!state.capability) return;
    try {
      const response = await api('/api/jobs');
      state.jobs = response.jobs || [];
      const previous = state.job ? state.job.id : null;
      if (state.job) state.job = state.jobs.find((item) => item.id === state.job.id) || state.job;
      else state.job = state.jobs.find((item) => ['queued', 'running', 'stop_requested'].indexOf(item.state) >= 0) || state.jobs[0] || null;
      if (state.job && state.job.id !== previous) { state.offset = 0; state.log = ''; }
      renderJobs();
      if (state.job) await readJob(state.job.id);
      schedulePoll();
    } catch (error) {
      $('job-observation').textContent = '读取任务失败：' + error.message;
    }
  }
  function schedulePoll() {
    clearTimeout(state.poll);
    if (!state.job || !state.capability) return;
    if (['queued', 'running', 'stop_requested'].indexOf(state.job.state) >= 0) {
      state.poll = setTimeout(refreshJobs, 2500);
    }
  }
  function renderJobs() {
    const area = $('job-list'); if (!area) return;
    area.replaceChildren();
    if (!state.jobs.length) { area.append(el('p', '尚无任务。', 'empty-state')); return; }
    state.jobs.slice(0, 8).forEach((job) => {
      const button = el('button', '', 'job-item' + (state.job && state.job.id === job.id ? ' active' : ''));
      button.type = 'button'; button.append(el('strong', job.state), el('small', job.id));
      button.addEventListener('click', () => { state.job = job; state.offset = 0; state.log = ''; renderJobs(); readJob(job.id); });
      area.append(button);
    });
    $('job-detail').hidden = !state.job;
    if (state.job) {
      const stageLabel = state.job.stage === 'add-workers' ? 'worker 扩容' : (state.job.stage || 'all');
      $('job-heading').textContent = '任务 ' + state.job.state + ' · ' + stageLabel;
      $('job-summary').textContent = 'ID：' + state.job.id + ' · 创建：' + state.job.created_at + ' · ' + (state.job.message || '');
      $('job-observation').textContent = state.job.updated_at ? '最近更新：' + state.job.updated_at : '';
    }
    renderStageProgress(); syncButtons();
  }
  async function readJob(identifier) {
    try {
      const job = await api('/api/jobs/' + encodeURIComponent(identifier));
      if (state.job && state.job.id === identifier) state.job = job;
      const response = await api('/api/jobs/' + encodeURIComponent(identifier) + '/logs?offset=' + state.offset);
      state.log += response.text || ''; state.offset = response.next_offset || state.offset;
      $('job-log').textContent = state.log.slice(-200000);
      $('job-log').scrollTop = $('job-log').scrollHeight;
      renderJobs(); schedulePoll();
    } catch (error) { $('job-observation').textContent = '日志读取失败：' + error.message; }
  }
  async function downloadLedger() {
    try {
      const response = await fetch('/api/ledger', {headers: {'X-Web-Token': token}, credentials: 'omit'});
      if (!response.ok) throw new Error('台账尚未生成或执行器不可用。');
      const blob = await response.blob(); const disposition = response.headers.get('Content-Disposition') || '';
      const match = /filename="([A-Za-z0-9._-]+)"/.exec(disposition);
      const name = match ? match[1] : 'environment-ledger.xlsx';
      const url = URL.createObjectURL(blob); const link = document.createElement('a');
      link.href = url; link.download = name; document.body.append(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      notice('台账已下载。', 'success');
    } catch (error) { notice('台账下载失败：' + error.message, 'error'); }
  }
  function goStep(step) {
    state.step = step;
    document.querySelectorAll('.wizard-step').forEach((section) => { section.hidden = Number(section.dataset.step) !== step; });
    document.querySelectorAll('.step-link').forEach((button) => button.classList.toggle('active', Number(button.dataset.stepTarget) === step));
    if (step === 3) refreshExecution();
  }
  function registerEvents() {
    document.querySelectorAll('.step-link').forEach((button) => button.addEventListener('click', () => goStep(Number(button.dataset.stepTarget))));
    $('open-help').addEventListener('click', () => $('help-dialog').showModal());
    $('close-help').addEventListener('click', () => $('help-dialog').close());
    $('close-help-bottom').addEventListener('click', () => $('help-dialog').close());
    $('preset-single').addEventListener('click', () => applyPreset('single'));
    $('preset-ha').addEventListener('click', () => applyPreset('ha'));
    $('use-package-artifact').addEventListener('click', () => {
      const path = suggestionPath();
      if (!path) { notice('没有可用的包内归档建议。', 'error'); return; }
      state.config.settings.ARTIFACT_FILE = path; state.config.settings.ARTIFACT_SHA256 = ''; state.config.settings.DEPS_MODE = 'iso';
      changed(); renderSettings(); notice('已填入包内归档；SHA256 将在后端自动匹配。', 'success');
    });
    $('export-env').addEventListener('click', exportEnv);
    $('import-env').addEventListener('click', () => $('import-env-file').click());
    $('import-env-file').addEventListener('change', () => importEnv($('import-env-file').files[0]));
    $('view-form').addEventListener('click', () => setConfigView(false));
    $('view-env').addEventListener('click', () => setConfigView(true));
    $('add-node').addEventListener('click', () => {
      if (!state.config || state.config.nodes.length >= 32) return;
      const node = {}; state.schema.node_fields.forEach((field) => { node[field.key] = clone(field.default === undefined ? '' : field.default); });
      let index = 1; while (state.config.nodes.some((row) => row.name === 'node' + index)) index += 1;
      node.name = 'node' + index; node.address = ''; node.internal_address = ''; node.roles = ['worker'];
      node.connection = 'ssh'; node.user = 'root'; node.port = 22; node.data_mode = 'native'; node.device = ''; node.password_env = 'NODE' + index + '_PASSWORD';
      state.config.nodes.push(node); changed(); renderNodes();
    });
    $('toggle-password-visibility').addEventListener('click', () => { state.showPasswords = !state.showPasswords; renderNodes(); renderCredentials(); });
    $('probe-nodes').addEventListener('click', probeNodes);
    $('refresh-clusters').addEventListener('click', refreshClusters);
    $('submit-expand-workers').addEventListener('click', submitExpandWorkers);
    $('validate-config').addEventListener('click', () => validateCurrent('validate'));
    $('show-plan').addEventListener('click', () => validateCurrent('plan'));
    $('next-step-2').addEventListener('click', () => goStep(2));
    $('back-step-1').addEventListener('click', () => goStep(1));
    $('next-step-3').addEventListener('click', () => goStep(3));
    $('back-step-2').addEventListener('click', () => goStep(2));
    $('start-deploy-direct').addEventListener('click', startDeployDirect);
    $('stage-prepare').addEventListener('click', () => startStage('prepare'));
    $('stage-harbor').addEventListener('click', () => startStage('harbor'));
    $('stage-k8s').addEventListener('click', () => startStage('k8s'));
    $('stop-current-job').addEventListener('click', stopCurrentJob);
    $('download-ledger').addEventListener('click', downloadLedger);
    window.addEventListener('beforeunload', (event) => { if (state.dirty) { event.preventDefault(); event.returnValue = ''; } });

  }
  async function start() {
    const fragment = new URLSearchParams(window.location.hash.slice(1));
    const supplied = fragment.get('token');
    if (supplied) {
      token = supplied;
      try { sessionStorage.setItem(TOKEN_KEY, token); } catch (_) { /* memory only */ }
      if (window.location.hash) history.replaceState(null, '', window.location.pathname + window.location.search);
    } else {
      try { token = sessionStorage.getItem(TOKEN_KEY) || ''; } catch (_) { token = ''; }
    }
    if (!token) { $('connection-panel').hidden = false; $('connection-message').textContent = '缺少访问令牌，请使用服务启动时输出的完整链接。'; return; }
    setBusy(true);
    try {
      const response = await api('/api/schema');
      state.schema = response.schema; state.defaults = response.default_config; state.suggestions = response.suggestions || {};
      registerEvents(); loadConfig(state.defaults); applyPreset('ha', false);
      await refreshExecution();
      $('wizard').hidden = false; goStep(1);
    } catch (error) {
      $('connection-panel').hidden = false; $('connection-message').textContent = '无法打开工作台：' + error.message;
    } finally { setBusy(false); }
  }
  start();
})();
