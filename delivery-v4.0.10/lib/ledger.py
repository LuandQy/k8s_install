"""Portable ledger exporter: Python stdlib only, no network or node operations."""
import csv
import hashlib
import html
import json
from pathlib import Path
import sys
from datetime import datetime, timezone
import zipfile
from xml.etree import ElementTree as ET


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def valid_cluster_evidence(evidence, config):
    """Require completed checks and cleanup; a success label alone is insufficient."""
    try:
        requested = config.get('storage', {}).get('local_enabled', True)
        if type(requested) is not bool:
            return False
        scope, checks, cleanup = evidence['scope'], evidence['checks'], evidence['cleanup']
        if evidence['schema'] != 1 or evidence['status'] != 'passed':
            return False
        mode = config.get('verification', {}).get('mode', 'selected-node')
        if mode not in ('selected-node', 'cross-node') or scope['mode'] != mode or scope['storage_requested'] is not requested:
            return False
        if scope['node'] not in {n['name'] for n in config['nodes']}:
            return False
        if any(checks[key]['status'] != 'passed' for key in ('dns', 'api_tls', 'api_alias', 'harbor_tls', 'service')):
            return False
        if cleanup['status'] != 'passed' or cleanup['namespace_absent'] is not True:
            return False
        if evidence['io_guard']['status'] != 'passed' or evidence['io_guard']['new_errors'] != 0:
            return False
        if mode == 'cross-node' and not valid_cross_node_evidence(evidence, config):
            return False
        if requested:
            return (checks['storage']['status'] == 'passed' and
                    cleanup['test_pv_absent'] is True and cleanup['test_directory_absent'] is True)
        return checks['storage']['status'] == 'skipped' and bool(checks['storage'].get('reason'))
    except (KeyError, TypeError, AttributeError):
        return False


def valid_cross_node_evidence(evidence, config):
    """Cross-node success must cover every declared Kubernetes node and direction."""
    try:
        roles = lambda n: n.get('roles', '').split(',') if isinstance(n.get('roles', ''), str) else n['roles']
        nodes = {n['name'] for n in config['nodes'] if set(roles(n)) & {'control_plane', 'worker'}}
        scope, proof = evidence['scope'], evidence['checks']['cross_node']
        if len(nodes) < 2 or proof['status'] != 'passed' or set(proof['nodes']) != nodes or len(proof['nodes']) != len(nodes):
            return False
        if (scope['network_all_nodes_verified'] is not True or scope['cross_node_tested'] is not True or
                scope['all_nodes_verified'] is not False or scope['ha_tested'] is not False or set(scope['network_nodes_requested']) != nodes):
            return False
        if scope['storage_nodes'] != ([scope['node']] if scope['storage_requested'] else []):
            return False
        if set(proof['node_uids']) != nodes or not all(isinstance(x, str) and x for x in proof['node_uids'].values()):
            return False
        if set(proof['network_checks']) != nodes:
            return False
        for result in proof['network_checks'].values():
            if any(result[k]['status'] != 'passed' for k in ('dns', 'api_alias', 'api_tls', 'harbor_tls')):
                return False
        expected = {(a, b) for a in nodes for b in nodes if a != b}
        actual = []
        for pair in proof['pairs']:
            if pair['status'] != 'passed' or not pair['client_uid'] or not pair['server_uid']:
                return False
            paths = pair['paths']
            if len(paths) != 3 or len({p['address'] for p in paths}) != 3 or not all(p['matched'] is True for p in paths):
                return False
            if len({p['sha256'] for p in paths}) != 1 or not all(isinstance(p['sha256'], str) and len(p['sha256']) == 64 for p in paths):
                return False
            actual.append((pair['source_node'], pair['target_node']))
        if len(actual) != len(expected) or set(actual) != expected:
            return False
        io = evidence['io_guard']
        return io['scope'] == 'selected_execution_node' and set(io['unmonitored_nodes']) == nodes - {scope['node']}
    except (KeyError, TypeError, AttributeError):
        return False


def collect(config, state, fingerprint):
    wf = Path(str(state) + '.workflow')
    stages, evidence, issues = [], {}, []
    if wf.exists():
        for p in sorted(wf.glob('*.json')):
            if p.name in ('identity.json', 'access-identity.json'):
                continue
            try:
                record = read(p)
                if not isinstance(record, dict) or 'stage' not in record:
                    continue
                status = record.get('status', 'unknown')
                if record.get('fingerprint') != fingerprint:
                    status = 'stale'
                ev = record.get('evidence')
                if status == 'succeeded' and ev:
                    if sha(ev['path']) != ev['sha256']:
                        raise ValueError('evidence checksum mismatch')
                    evidence[record['stage']] = read(ev['path'])
                stages.append(dict({k: record.get(k, '') for k in ('stage', 'run', 'updated_at')}, status=status))
            except (ValueError, OSError, KeyError, TypeError):
                issues.append(f'{p.name}: invalid or missing evidence')
                stages.append({'stage': p.stem, 'status': 'invalid', 'run': '', 'updated_at': ''})
    statuses = {s['stage']: s['status'] for s in stages}
    validators = {
        'access': lambda e: isinstance(e, list) and bool(e) and all(n.get('machine_id') for n in e),
        'prepare': lambda e: bool(e.get('identity')) and bool(e.get('storage')),
        'services-init': lambda e: bool(e.get('nodes')),
        'services-verify': lambda e: bool(e.get('nodes')),
        'images-verify': lambda e: bool(e.get('images')),
        'node-images-verify': lambda e: bool(e.get('images')),
        'cluster-verify': lambda e: valid_cluster_evidence(e, config),
    }
    for stage, validate in validators.items():
        if statuses.get(stage) == 'succeeded':
            try:
                valid = stage in evidence and validate(evidence[stage])
            except (AttributeError, TypeError):
                valid = False
            if not valid:
                issues.append(f'{stage}: missing or empty acceptance evidence')
                evidence.pop(stage, None)
    try:
        if Path(str(state)+'.deployment/status').read_text().strip() == 'reset':
            issues.append('cluster has been reset')
    except OSError:
        pass
    if Path(str(state)+'.expansion').exists():
        issues.append('worker expansion pending')
    required = ['access', 'prepare', 'deps', 'services-init', 'services-verify']
    if config['scope'] != 'k8s':
        required += ['harbor-install']
    if config['scope'] == 'harbor' and config.get('import_images',False):
        required += ['images-verify']
    if config['scope'] != 'harbor':
        required += ['images-verify', 'k8s-install', 'node-images-verify', 'cluster-verify']
    for stage in required:
        if statuses.get(stage) != 'succeeded':
            issues.append(f'{stage}: required stage has not succeeded')
    # A ledger is an observation of recorded checks, never a new live-health claim.
    accepted = all(statuses.get(s) == 'succeeded' for s in required) and not issues
    for s in ['access', 'prepare', 'services-verify']:
        if statuses.get(s) == 'succeeded' and s not in evidence:
            issues.append(f'{s}: missing acceptance evidence')
    if config['scope'] != 'harbor' and statuses.get('node-images-verify') == 'succeeded' and 'node-images-verify' not in evidence:
        issues.append('node-images-verify: missing acceptance evidence')
    observed_cluster = None
    try:
        checksums = dict((line.split()[1], line.split()[0]) for line in (state / 'SHA256SUMS').read_text().splitlines())
        if checksums['identity.json'] == sha(state / 'identity.json'):
            raw = read(state / 'identity.json')
            observed_cluster = {k: raw.get(k) for k in ('uid', 'version', 'nodes')}
    except (OSError, KeyError, ValueError, IndexError, TypeError):
        pass
    if config['scope'] != 'harbor' and statuses.get('k8s-install') == 'succeeded' and observed_cluster is None:
        issues.append('cluster: missing or invalid identity receipt')
    disks = {}
    # Include only non-secret hardware/mount fields from signed prepare evidence.
    def clean_device(device):
        allowed = ('name','type','size','model','serial','fstype','mountpoint','ro','target','avail')
        result = {k:device[k] for k in allowed if k in device}
        if str(device.get('source','')).startswith(('/dev/','UUID=')):
            result['source'] = device['source']
        if device.get('children'):
            result['children'] = [clean_device(c) for c in device['children']]
        return result
    for n, info in evidence.get('prepare', {}).get('snapshots', {}).items():
        disks[n] = {'blocks':[clean_device(v) for v in info.get('blocks', {}).get('blockdevices', [])],
                    'mounts':[clean_device(v) for v in info.get('mounts', {}).get('filesystems', [])],
                    'system': info.get('system', {})}
    # Do not export the unsanitized copies (mount options may contain site secrets).
    if 'prepare' in evidence:
        evidence['prepare'].pop('snapshots', None)
    return {'schema': 1, 'generated_at': datetime.now(timezone.utc).isoformat(),
            'status': 'recorded_checks_passed' if accepted and not issues else 'draft_or_incomplete',
            'live_health_checked': False, 'planned': config, 'observed_cluster': observed_cluster,
            'stages': stages, 'evidence': evidence, 'preparation_disk_observations': disks, 'issues': issues}


def tables(data):
    cfg = data['planned']
    overview = [['项目', '值'], ['集群', cfg['cluster']], ['台账状态', data['status']],
                ['采集时间 UTC', data['generated_at']], ['实时健康检查', '否，汇总阶段验收记录'],
                ['计划 K8s', cfg['kubernetes']], ['KubeKey', cfg['kubekey']],
                ['实际集群 UID', (data['observed_cluster'] or {}).get('uid', '未采集')],
                ['实际 K8s', (data['observed_cluster'] or {}).get('version', '未采集')]]
    prepared = {n['node']:n for n in data['evidence'].get('prepare', {}).get('storage',[])}
    observed = {n['name']:n for n in (data['observed_cluster'] or {}).get('nodes',[]) or []}
    nodes = [['名称', 'SSH IP', '内部 IP', '账号', '端口', '角色', '计划架构', '依赖包', '数据策略', '数据目录', '设备', '已执行存储策略', '已执行数据目录', '实际 K8s', '实际架构', 'Ready（记录值）']]
    for n in cfg['nodes']:
        actual=observed.get(n['name'],{}); storage=prepared.get(n['name'],{})
        nodes.append([n.get(k, '') for k in ('name', 'address', 'internal_ip', 'user', 'port', 'roles', 'arch', 'os_package', 'storage_mode', 'data_path', 'device')]+[storage.get('mode','未采集'),storage.get('path','未采集'),actual.get('version','未采集'),actual.get('arch','未采集'),actual.get('ready','未采集')])
    services = [['节点', 'NTP 角色', '配置时间源', 'NTP 验收', 'NFS 服务端', '共享路径', 'NFS 验收']]
    for n in data['evidence'].get('services-verify', data['evidence'].get('services-init', {})).get('nodes', []):
        services.append([n['node'], n['ntp']['mode'], n['ntp']['sources'], n['ntp']['evidence'], n['nfs']['server'], n['nfs']['path'], n['nfs']['evidence']])
    images = [['节点', '架构', '镜像', 'Harbor 摘要', '运行时摘要', '验收']]
    for n in data['evidence'].get('node-images-verify', {}).get('images', []):
        images.append([n['node'], n['arch'], n['image'], n['registry_digest'], ', '.join(n['repo_digests']), n['result']])
    stages = [['阶段', '状态', '记录时间 UTC', '运行目录']] + [[s[k] for k in ('stage', 'status', 'updated_at', 'run')] for s in data['stages']]
    plan = [['类别', '配置项', '配置值']]
    for section in ('network', 'registry', 'ntp', 'nfs'):
        plan += [[section, k, v] for k, v in cfg[section].items()]
    disks = [['节点', '检查时点', '磁盘与挂载 JSON']]
    disks += [[n, 'prepare 前检查', json.dumps(v, ensure_ascii=False)] for n, v in data['preparation_disk_observations'].items()]
    functional = [['验收项', '记录状态', '范围/证据']]
    acceptance = data['evidence'].get('cluster-verify', {})
    if acceptance:
        functional.append(['验收范围', acceptance.get('status', 'unknown'), json.dumps(acceptance.get('scope', {}), ensure_ascii=False)])
        for name, proof in acceptance.get('checks', {}).items():
            functional.append([name, proof.get('status', 'unknown'), json.dumps(proof, ensure_ascii=False)])
        for name in ('cleanup', 'io_guard'):
            proof = acceptance.get(name, {})
            functional.append([name, proof.get('status', 'unknown'), json.dumps(proof, ensure_ascii=False)])
    else:
        functional.append(['cluster-verify', '未取得有效验收记录', '此表仅汇总阶段记录，不会执行现场测试'])
    issues = [['待核对事项']] + [[s] for s in data['issues']]
    return {'环境概览': overview, '主机清单': nodes, '网络与服务规划': plan, 'NTP与NFS验收': services,
            '磁盘与挂载': disks, '节点镜像验收': images, '集群功能验收': functional, '执行记录': stages, '待核对事项': issues}


def xlsx(path, sheets):
    # Inline strings deliberately prevent formulas, external links and credentials.
    ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    package = 'http://schemas.openxmlformats.org/package/2006/relationships'
    types = 'http://schemas.openxmlformats.org/package/2006/content-types'
    wb = ET.Element('workbook', xmlns=ns)
    ws = ET.SubElement(wb, 'sheets')
    links = ET.Element('Relationships', xmlns=package)
    ct = ET.Element('Types', xmlns=types)
    ET.SubElement(ct, 'Default', Extension='rels', ContentType='application/vnd.openxmlformats-package.relationships+xml')
    ET.SubElement(ct, 'Default', Extension='xml', ContentType='application/xml')
    ET.SubElement(ct, 'Override', PartName='/xl/workbook.xml', ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml')
    rootrels = ET.Element('Relationships', xmlns=package)
    ET.SubElement(rootrels, 'Relationship', Id='rId1', Type=rel+'/officeDocument', Target='xl/workbook.xml')
    def xml(e):
        return ET.tostring(e, encoding='utf-8', xml_declaration=True)
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for i, (name, rows) in enumerate(sheets.items(), 1):
            ET.SubElement(ws, 'sheet', name=name, sheetId=str(i), attrib={f'{{{rel}}}id': f'rId{i}'})
            ET.SubElement(links, 'Relationship', Id=f'rId{i}', Type=rel+'/worksheet', Target=f'worksheets/sheet{i}.xml')
            ET.SubElement(ct, 'Override', PartName=f'/xl/worksheets/sheet{i}.xml', ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml')
            sheet = ET.Element('worksheet', xmlns=ns)
            views = ET.SubElement(sheet, 'sheetViews')
            view = ET.SubElement(views, 'sheetView', workbookViewId='0')
            ET.SubElement(view, 'pane', ySplit='1', topLeftCell='A2', activePane='bottomLeft', state='frozen')
            cols = ET.SubElement(sheet, 'cols')
            for col in range(1, max(map(len, rows))+1):
                ET.SubElement(cols, 'col', min=str(col), max=str(col), width='28', customWidth='1')
            sd = ET.SubElement(sheet, 'sheetData')
            for ri, row in enumerate(rows, 1):
                er = ET.SubElement(sd, 'row', r=str(ri))
                for ci, val in enumerate(row, 1):
                    letters = ''; n = ci
                    while n:
                        n, rem = divmod(n-1, 26); letters = chr(65+rem)+letters
                    cell = ET.SubElement(er, 'c', r=f'{letters}{ri}', t='inlineStr')
                    text = ''.join(c for c in str(val) if c in '\n\r\t' or ord(c) >= 32)[:32767]
                    ET.SubElement(ET.SubElement(cell, 'is'), 't', {'{http://www.w3.org/XML/1998/namespace}space':'preserve'}).text = text
            z.writestr(f'xl/worksheets/sheet{i}.xml', xml(sheet))
        z.writestr('xl/workbook.xml', xml(wb)); z.writestr('xl/_rels/workbook.xml.rels', xml(links))
        z.writestr('_rels/.rels', xml(rootrels)); z.writestr('[Content_Types].xml', xml(ct))


def export(data, out):
    sheets = tables(data)
    (out/'environment-ledger.json').write_text(json.dumps(data, ensure_ascii=False, indent=2))
    xlsx(out/'environment-ledger.xlsx', sheets)
    body = ['<!doctype html><meta charset="utf-8"><title>环境台账</title><style>body{font:14px sans-serif;margin:24px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:8px;white-space:pre-wrap;overflow-wrap:anywhere;max-width:600px}th{background:#eee}</style>']
    for name, rows in sheets.items():
        body.append('<h2>'+html.escape(name)+'</h2><table>')
        for i, row in enumerate(rows):
            tag = 'th' if i == 0 else 'td'
            body.append('<tr>'+''.join(f'<{tag}>{html.escape(str(v))}</{tag}>' for v in row)+'</tr>')
        body.append('</table>')
        with (out/(name+'.csv')).open('w', encoding='utf-8-sig', newline='') as f:
            writer = csv.writer(f)
            writer.writerows([[("'"+str(v)) if str(v).lstrip().startswith(('=', '+', '-', '@')) else v for v in row] for row in rows])
    (out/'environment-ledger.html').write_text('\n'.join(body))


if __name__ == '__main__':
    cfg, state, fingerprint, output = sys.argv[1:]
    export(collect(read(cfg), Path(state), fingerprint), Path(output))
