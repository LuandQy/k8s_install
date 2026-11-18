#!/usr/bin/env python3
"""Simulate Web Workbench End-to-End Automation for Pipeline B."""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

from verify_ledger import verify_ledger

class WebClient:
    def __init__(self, base_url, token):
        self.base_url = base_url.rstrip('/')
        self.token = token
        # Parse host for headers
        match = re.match(r'https?://([^/]+)', self.base_url)
        self.host = match.group(1) if match else '127.0.0.1:8765'

    def request(self, method, path, data=None):
        url = f"{self.base_url}{path}"
        headers = {
            'Host': self.host,
            'X-Web-Token': self.token,
            'Sec-Fetch-Site': 'same-origin',
        }
        if method in ('POST', 'PUT'):
            headers['Origin'] = f"http://{self.host}"
        
        body_bytes = None
        if data is not None:
            headers['Content-Type'] = 'application/json'
            body_bytes = json.dumps(data, ensure_ascii=False).encode('utf-8')
            headers['Content-Length'] = str(len(body_bytes))

        req = urllib.request.Request(url, data=body_bytes, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                content_type = resp.headers.get('Content-Type', '')
                raw = resp.read()
                if 'application/json' in content_type:
                    return json.loads(raw.decode('utf-8'))
                return raw
        except urllib.error.HTTPError as e:
            err_body = e.read().decode('utf-8', errors='replace')
            print(f"[HTTP {e.code} Error on {method} {path}]: {err_body}")
            raise

    def get_schema(self):
        return self.request('GET', '/api/schema')

    def get_execution(self):
        return self.request('GET', '/api/execution')

    def import_env(self, env_text):
        return self.request('POST', '/api/import', {'text': env_text})

    def validate_config(self, config):
        return self.request('POST', '/api/validate', {'config': config})

    def plan_config(self, config):
        return self.request('POST', '/api/plan', {'config': config})

    def preview_job(self, config, stage='all'):
        return self.request('POST', '/api/jobs/preview', {'config': config, 'stage': stage})

    def submit_job(self, plan_id, config_sha256, credentials, stage='all', debug=False):
        req_id = str(uuid.uuid4())
        payload = {
            'request_id': req_id,
            'plan_id': plan_id,
            'config_sha256': config_sha256,
            'acknowledged': True,
            'credentials': credentials,
            'debug': debug,
            'stage': stage
        }
        return self.request('POST', '/api/jobs', payload)

    def get_job(self, job_id):
        return self.request('GET', f'/api/jobs/{job_id}')

    def get_job_logs(self, job_id, offset=0):
        return self.request('GET', f'/api/jobs/{job_id}/logs?offset={offset}')

    def download_ledger(self, output_path):
        raw = self.request('GET', '/api/ledger')
        with open(output_path, 'wb') as f:
            f.write(raw)
        print(f"Ledger saved to {output_path} ({len(raw)} bytes)")

def wait_for_job(client, job_id, poll_interval=10, timeout=1200):
    start = time.time()
    last_offset = 0
    print(f"\n--- Monitoring Job {job_id} ---")
    while time.time() - start < timeout:
        job = client.get_job(job_id)
        status = job.get('state') or job.get('status')
        # fetch logs
        try:
            logs_resp = client.get_job_logs(job_id, offset=last_offset)
            new_text = logs_resp.get('text', '')
            if new_text:
                for line in new_text.splitlines():
                    print(f"  [JOB LOG] {line}")
            last_offset = logs_resp.get('next_offset', last_offset)
        except Exception:
            pass

        if status == 'succeeded':
            elapsed = int(time.time() - start)
            print(f"==> Job {job_id} SUCCEEDED in {elapsed}s <==")
            return job
        elif status in ('failed', 'stopped'):
            error = job.get('error', {})
            raise RuntimeError(f"Job {job_id} {status}: {error.get('code')} - {error.get('message')}")
        
        time.sleep(poll_interval)
    raise TimeoutError(f"Job {job_id} timed out after {timeout}s")

def build_credentials(plan, root_password="Test@123456", harbor_password="Test@12345678"):
    creds = {}
    for spec in plan.get('required_credentials', []):
        key = spec['key']
        if key == 'harbor':
            creds[key] = harbor_password
        elif key.startswith('node:'):
            creds[key] = root_password
        else:
            creds[key] = root_password
    return creds

def main():
    parser = argparse.ArgumentParser(description="Web E2E Deployment Runner")
    parser.add_argument('--url', default='http://127.0.0.1:8765', help="Workbench URL")
    parser.add_argument('--token', required=True, help="Workbench web_token")
    parser.add_argument('--env-file', required=True, help="cluster-vars.env file")
    parser.add_argument('--ledger-out', default='web_ledger.xlsx', help="Ledger output path")
    parser.add_argument('--start-stage', default='prepare', choices=['prepare', 'harbor', 'k8s'], help="Stage to start from")
    args = parser.parse_args()

    client = WebClient(args.url, args.token)

    print("[Step 0] Testing connection to Web Workbench...")
    schema = client.get_schema()
    print("  Discovered schema version:", schema.get('schema', {}).get('$schema', 'valid'))
    exec_caps = client.get_execution()
    print("  Execution capabilities:", exec_caps)
    assert exec_caps.get('enabled') is True, "Privileged executor is not enabled!"

    print("\n[Step 01] Importing and validating cluster-vars.env...")
    with open(args.env_file, 'r', encoding='utf-8') as f:
        env_text = f.read()

    imported = client.import_env(env_text)
    config = imported['config']
    cluster_name = config.get('settings', {}).get('CLUSTER_NAME') or config.get('cluster')
    print(f"  Imported config for cluster '{cluster_name}', {len(config.get('nodes', []))} nodes")

    print("\n[Step 02] Running static validation & read-only plan...")
    val_res = client.validate_config(config)
    print("  Validation response:", val_res)

    plan_res = client.plan_config(config)
    print(f"  Plan generated successfully. Stages: {[s['name'] for s in plan_res.get('stages', [])]}")

    all_stages = ['prepare', 'harbor', 'k8s']
    start_idx = all_stages.index(args.start_stage)
    stages = all_stages[start_idx:]
    for stage in stages:
        print(f"\n==========================================")
        print(f"[Step 03] Triggering Stage: '{stage}'")
        print(f"==========================================")
        preview = client.preview_job(config, stage=stage)
        plan_id = preview['plan_id']
        config_sha = preview['config_sha256']
        creds = build_credentials(preview)
        print(f"  Plan ID: {plan_id}, SHA: {config_sha[:16]}..., Credential keys: {list(creds.keys())}")

        sub_resp = client.submit_job(plan_id, config_sha, creds, stage=stage)
        job_id = sub_resp.get('id') or sub_resp.get('job', {}).get('id')
        print(f"  Submitted Job ID: {job_id}")

        wait_for_job(client, job_id, poll_interval=10)

        # Stage specific assertions
        if stage == 'prepare':
            print("  [Verify Prepare] Inspecting nodes for /data symlinks & chrony...")
            check_cmd = "ssh -o StrictHostKeyChecking=no root@192.168.64.4 'ls -la /var/lib/containerd && [ ! -L /var/lib/etcd ] && chronyc tracking'"
            subprocess.run(check_cmd, shell=True, check=True)
            print("  -> Prepare verification passed!")
        elif stage == 'harbor':
            print("  [Verify Harbor] Checking Harbor containers & HTTPS...")
            check_cmd = "ssh -o StrictHostKeyChecking=no root@192.168.64.4 'docker ps --format \"{{.Names}}: {{.Status}}\" | grep -i harbor && curl -k -s -o /dev/null -w \"%{http_code}\" https://192.168.64.4'"
            subprocess.run(check_cmd, shell=True, check=True)
            print("  -> Harbor verification passed!")
        elif stage == 'k8s':
            print("  [Verify K8s] Checking K8s nodes and pods...")
            check_cmd = "ssh -o StrictHostKeyChecking=no root@192.168.64.4 'kubectl get nodes -o wide && kubectl get pods -A'"
            subprocess.run(check_cmd, shell=True, check=True)
            print("  -> K8s cluster verification passed!")

    print(f"\n==========================================")
    print(f"[Step 04] Downloading and Verifying Ledger Excel...")
    print(f"==========================================")
    client.download_ledger(args.ledger_out)

    print("  Verifying ledger structure and data...")
    verify_ledger(args.ledger_out)
    print("\n[SUCCESS] Pipeline B Web E2E Deployment & Ledger Verification Complete!")

if __name__ == '__main__':
    main()
