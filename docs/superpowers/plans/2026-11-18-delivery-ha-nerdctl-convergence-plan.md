# HA Odd-Quorum, K8s Nerdctl Preinstall & Delivery Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce 1/3/5… odd-quorum co-located Master/Etcd HA topology, pre-install `nerdctl` v2.2.1 + `/etc/nerdctl/nerdctl.toml` on K8s nodes by default (`INSTALL_NERDCTL=true`), unify Web/CLI schema & visibility contracts, close BYO-CA/workflow/maintenance gaps, add `SSH_PARALLEL` node execution & `JobLog` secret masking + head/tail retention, and establish automated release verification.

**Architecture:** `delivery-v4.0.10/web/schema.json` acts as the single declarative source of truth for all setting defaults and `visible_when` field visibility across Python (`config_model.py`), Bash (`schema-defaults.py` / `config.sh`), and JS (`workbench-logic.js` / `app.js`). Pre-installation of `nerdctl` uses an idempotent POSIX/Bash node script (`node_scripts/nerdctl.sh`) fed from checksum-verified bundled archives (`artifact/tools/{amd64,arm64}/nerdctl-2.2.1-linux-*.tar.gz`). Post-maintenance convergence (`lib/post-verify.sh`), bounded parallel SSH (`node_run_parallel`), and `JobLog` ring-tail retention extend existing seams without introducing external dependencies.

**Tech Stack:** Bash 4.4+ (controller) / POSIX sh (node scripts), Python 3.8+ standard library (`unittest`, `http.server`, `socketserver`), Vanilla ES6 / CommonJS JavaScript (`node` test runner), KubeKey v4.0.10 YAML playbooks.

**Spec:** `docs/superpowers/specs/2026-11-18-delivery-ha-nerdctl-convergence-design.md`

## Global Constraints

- Zero third-party Python or Node runtime dependencies.
- Keep `docs/superpowers/` and `release.sh` in the outer workspace root (`/Users/y.q/demo/delivery/`), never inside `delivery-v4.0.10/`, so delivery manifests remain clean of internal development artifacts.
- Preserve existing 67 Python unit tests (including `JobLog()` with no `secrets` leaving arbitrary text unredacted).
- Do not re-compress the 6.7 GiB outer `.tar.gz` archive by default; refresh and verify `delivery-v4.0.10/SOURCE_SHA256SUMS` and `delivery-v4.0.10/SHA256SUMS` with zero `__pycache__` or `._*` files left behind.

---

### Task 1: Schema Single-Source-of-Truth, Missing Fields (`INSTALL_NERDCTL`, `PKI_ROOT_*`, `SSH_KNOWN_HOSTS*`, `ZONE`), and Odd Master/Etcd Topology Validation

**Files:**
- Modify: `delivery-v4.0.10/web/schema.json`
- Modify: `delivery-v4.0.10/web/config_model.py`
- Modify: `delivery-v4.0.10/web/static/workbench-logic.js`
- Modify: `delivery-v4.0.10/web/static/app.js`
- Modify: `delivery-v4.0.10/lib/config.sh`
- Modify: `delivery-v4.0.10/lib/wizard-nodes.sh`
- Modify: `delivery-v4.0.10/lib/wizard.sh`
- Modify: `delivery-v4.0.10/lib/cluster-state.sh`
- Modify: `delivery-v4.0.10/cluster-vars.env.example`
- Test: `delivery-v4.0.10/tests/workbench-logic.test.js`
- Create: `delivery-v4.0.10/tests/test_ha_and_nerdctl.py`

**Interfaces:**
- Produces in `workbench-logic.js`:
  - `schemaRules(schemaObj)` → `{[key]: visibleWhenRule}`
  - `validateMasterEtcdTopology(nodes, components)` → `{valid: boolean, masterCount: number, etcdCount: number, coLocated: boolean, reason: string}`
  - `syncMasterEtcdRoles(roles, toggledRole, checked)` → `string[]`
  - `ruleVisible(rule, values)` supporting `all`, `any`, `equals`, `notEquals`, `in`, `notIn`
- Produces in `config_model.py`:
  - `validate_topology(config)` → raises `ModelError` on invalid Master/Etcd quorum, non-co-located Master/Etcd, or `<3` / `>=3` endpoint mismatch

- [ ] **Step 1: Write failing JS & Python tests for odd Master/Etcd quorum, `INSTALL_NERDCTL`, schema `visible_when`, and `examples/*.env` round-trip**
- [ ] **Step 2: Run JS and Python tests to verify RED failure**
- [ ] **Step 3: Implement `schema.json`, `config_model.py`, `workbench-logic.js`, `app.js`, `lib/config.sh`, `lib/wizard*.sh`, `lib/cluster-state.sh`, `cluster-vars.env.example`**
- [ ] **Step 4: Run JS and Python tests to verify GREEN**
- [ ] **Step 5: Commit Task 1**

---

### Task 2: K8s Node Pre-Script `nerdctl` Installation & `/etc/nerdctl/nerdctl.toml` Configuration

**Files:**
- Create: `delivery-v4.0.10/node_scripts/nerdctl.sh`
- Modify: `delivery-v4.0.10/lib/artifact.sh`
- Modify: `delivery-v4.0.10/init.sh`
- Modify: `delivery-v4.0.10/lib/render.sh`
- Modify: `delivery-v4.0.10/config-base.yaml`
- Modify: `delivery-v4.0.10/kk-project/roles/rise/verify/tasks/main.yaml`
- Test: `delivery-v4.0.10/tests/test_ha_and_nerdctl.py`

**Interfaces:**
- Produces `node_scripts/nerdctl.sh <archive_path> [expected_arch]`:
  - Extracts `nerdctl` from `nerdctl-2.2.1-linux-{amd64,arm64}.tar.gz` into `${NERDCTL_DEST_ROOT}/usr/local/bin` when `nerdctl` is not already present; ensures `0755` mode.
  - Creates `${NERDCTL_DEST_ROOT}/etc/nerdctl/nerdctl.toml` with `namespace = "k8s.io"`, `cgroup_manager = "cgroupfs"`, `hosts_dir = ["/etc/containerd/certs.d", "/etc/docker/certs.d"]` if absent.
- Produces in `lib/artifact.sh`:
  - `resolve_nerdctl_archive <arch>` (checksum-verified against `artifact/SHA256SUMS`)
  - `install_k8s_nodes_nerdctl` (runs on active `control_plane`/`worker` nodes when `INSTALL_NERDCTL=true` and `COMPONENTS != harbor`)

- [ ] **Step 1: Write failing tests in `test_ha_and_nerdctl.py` testing real tarball extraction, `/etc/nerdctl/nerdctl.toml` generation, idempotency, and `INSTALL_NERDCTL` wiring**
- [ ] **Step 2: Run Python tests to verify RED failure**
- [ ] **Step 3: Implement `node_scripts/nerdctl.sh`, `lib/artifact.sh`, `init.sh`, `lib/render.sh`, `config-base.yaml`, and `kk-project/roles/rise/verify/tasks/main.yaml`**
- [ ] **Step 4: Run Python tests to verify GREEN**
- [ ] **Step 5: Commit Task 2**

---

### Task 3: BYO CA Receipt Persistence, State Machine Fixes, & Post-Maintenance `.workflow` Convergence

**Files:**
- Modify: `delivery-v4.0.10/lib/resume.sh`
- Modify: `delivery-v4.0.10/lib/prepared-config.sh`
- Modify: `delivery-v4.0.10/lib/workflow.sh`
- Create: `delivery-v4.0.10/lib/post-verify.sh`
- Modify: `delivery-v4.0.10/deploy.sh`
- Modify: `delivery-v4.0.10/redeploy.sh`
- Modify: `delivery-v4.0.10/scale-worker.sh`
- Modify: `delivery-v4.0.10/web/execution.py`
- Test: `delivery-v4.0.10/tests/test_ha_and_nerdctl.py`
- Test: `delivery-v4.0.10/tests/test_web.py`

**Interfaces:**
- Produces `workflow_sync_and_post_verify` in `lib/post-verify.sh`
- Enforces `config_sha256` match & terminal-completion guard in `ExecutionService.submit()` `is_continuation`

- [ ] **Step 1: Write failing tests for BYO CA receipt persistence, `workflow.sh` `workflow_status access`, `is_continuation` guards, and `post-verify.sh` integration**
- [ ] **Step 2: Run tests to verify RED failure**
- [ ] **Step 3: Implement BYO CA receipt fixes, `workflow.sh` fix, `post-verify.sh` + `deploy.sh`/`redeploy.sh`/`scale-worker.sh` integration, and `execution.py` `is_continuation` guards**
- [ ] **Step 4: Run tests to verify GREEN**
- [ ] **Step 5: Commit Task 3**

---

### Task 4: `node_run_parallel` (`SSH_PARALLEL`) & `JobLog` Exact Credential Masking + Head/Tail Retention

**Files:**
- Modify: `delivery-v4.0.10/lib/common.sh`
- Modify: `delivery-v4.0.10/lib/workflow.sh`
- Modify: `delivery-v4.0.10/lib/components.sh`
- Modify: `delivery-v4.0.10/lib/artifact.sh`
- Modify: `delivery-v4.0.10/init.sh`
- Modify: `delivery-v4.0.10/web/execution.py`
- Test: `delivery-v4.0.10/tests/test_web.py`
- Test: `delivery-v4.0.10/tests/test_ha_and_nerdctl.py`

**Interfaces:**
- Produces `node_run_parallel <max_parallel> <worker_fn> <lines_data>` in `lib/common.sh`
- Produces `JobLog(secrets=None)` + `LogBuffer(max_bytes=MAX_LOG, head_bytes=1048576)` in `web/execution.py`

- [ ] **Step 1: Write failing tests for `JobLog(secrets=...)`, >4 MiB head+tail log retention with monotonic offsets, and `node_run_parallel` concurrency + failure propagation**
- [ ] **Step 2: Run tests to verify RED failure**
- [ ] **Step 3: Implement `node_run_parallel` and `JobLog` + `LogBuffer` in `execution.py`**
- [ ] **Step 4: Run tests to verify GREEN**
- [ ] **Step 5: Commit Task 4**

---

### Task 5: Docs Update, `release.sh` Verification Pipeline, & Manifest Refresh

**Files:**
- Create: `release.sh`
- Modify: `delivery-v4.0.10/docs/optimization-backlog.md`
- Modify: `delivery-v4.0.10/README.md`
- Modify: `delivery-v4.0.10/SOURCE_SHA256SUMS` (via `refresh-checksums.sh`)
- Modify: `delivery-v4.0.10/SHA256SUMS` (via `refresh-checksums.sh`)

- [ ] **Step 1: Create `release.sh` and update docs (`README.md`, `docs/optimization-backlog.md`) to reflect odd Master/Etcd quorum, `INSTALL_NERDCTL`, secret-value log masking, and resolved backlog items**
- [ ] **Step 2: Run `./release.sh` end-to-end (clean bytecode, run Python + Node + `bash -n` tests, regenerate manifests, verify all SHA256 checksums)**
- [ ] **Step 3: Commit final verified state and verify clean `git status`**
