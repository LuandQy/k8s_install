#!/usr/bin/env python3
"""Ledger Excel Verification Script."""
import sys
import openpyxl

def verify_ledger(filepath):
    print(f"Loading ledger workbook: {filepath}")
    wb = openpyxl.load_workbook(filepath, data_only=True)
    sheets = wb.sheetnames
    print(f"Discovered sheets ({len(sheets)}): {sheets}")

    expected_sheets = [
        '环境概览', '主机清单', '网络与服务规划',
        'NTP与NFS验收', '磁盘与挂载', '节点镜像验收',
        '集群功能验收', '执行记录', '待核对事项'
    ]
    
    missing_sheets = [s for s in expected_sheets if s not in sheets]
    if missing_sheets:
        print(f"[WARNING] Missing expected sheets: {missing_sheets}")
    else:
        print("[OK] All 9 expected sheets are present.")

    results = {}

    # 1. 环境概览
    if '环境概览' in sheets:
        ws = wb['环境概览']
        overview = {ws.cell(r, 1).value: ws.cell(r, 2).value for r in range(1, ws.max_row + 1) if ws.cell(r, 1).value}
        results['overview'] = overview
        print("\n--- [环境概览] ---")
        for k, v in overview.items():
            print(f"  {k}: {v}")
        status = overview.get('台账状态')
        assert status == 'recorded_checks_passed', f"Expected recorded_checks_passed, got {status}"
        print("  -> 台账状态校验通过: recorded_checks_passed")

    # 2. 主机清单
    if '主机清单' in sheets:
        ws = wb['主机清单']
        headers = [ws.cell(1, c).value for c in range(1, ws.max_column + 1)]
        nodes = []
        for r in range(2, ws.max_row + 1):
            row = [ws.cell(r, c).value for c in range(1, ws.max_column + 1)]
            if any(row):
                nodes.append(dict(zip(headers, row)))
        results['nodes'] = nodes
        print(f"\n--- [主机清单] ({len(nodes)} 节点) ---")
        for n in nodes:
            print(f"  节点: {n.get('名称')} | IP: {n.get('内部 IP')} | 角色: {n.get('角色')} | 状态: {n.get('Ready（记录值）')}")
            assert n.get('内部 IP'), f"Missing internal IP for node {n.get('名称')}"
            assert n.get('Ready（记录值）') in (True, 'True', 'true', 'passed'), f"Node {n.get('名称')} not ready"
        print("  -> 节点就绪状态校验通过")

    # 3. 网络与服务规划
    if '网络与服务规划' in sheets:
        ws = wb['网络与服务规划']
        plan = []
        for r in range(2, ws.max_row + 1):
            sec, item, val = ws.cell(r, 1).value, ws.cell(r, 2).value, ws.cell(r, 3).value
            if sec or item or val:
                plan.append((sec, item, val))
        results['plan'] = plan
        print(f"\n--- [网络与服务规划] ---")
        for sec, item, val in plan:
            print(f"  [{sec}] {item} = {val}")

    # 4. 集群功能验收
    if '集群功能验收' in sheets:
        ws = wb['集群功能验收']
        functional = {}
        for r in range(2, ws.max_row + 1):
            item, status, proof = ws.cell(r, 1).value, ws.cell(r, 2).value, ws.cell(r, 3).value
            if item:
                functional[item] = status
        results['functional'] = functional
        print(f"\n--- [集群功能验收] ---")
        for k, v in functional.items():
            print(f"  {k}: {v}")
            if k in ('dns', 'api_tls', 'api_alias', 'harbor_tls', 'service', 'cleanup', 'io_guard'):
                assert v == 'passed', f"Cluster verification check {k} failed: {v}"
        print("  -> 集群功能全部通过 (passed)")

    # 5. 待核对事项
    if '待核对事项' in sheets:
        ws = wb['待核对事项']
        issues = [ws.cell(r, 1).value for r in range(2, ws.max_row + 1) if ws.cell(r, 1).value]
        results['issues'] = issues
        print(f"\n--- [待核对事项] ({len(issues)} 项) ---")
        if issues:
            for issue in issues:
                print(f"  [!] {issue}")
        else:
            print("  [OK] 无任何待核对异常事项 (0 issues)")
        assert len(issues) == 0, f"Expected 0 issues, but found: {issues}"

    print("\n==========================================")
    print(">>> 台账 Excel 全部数据结构与关键字段断言通过！<<<")
    print("==========================================")
    return results

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python verify_ledger.py <path_to_xlsx>")
        sys.exit(1)
    verify_ledger(sys.argv[1])
