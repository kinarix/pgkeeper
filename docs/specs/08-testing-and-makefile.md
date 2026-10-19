---
id: 08-testing-and-makefile
title: "08 — Testing Strategy, Local Clusters, Makefile Contract"
type: spec
status: design
version: 0.5.0
updated: 2026-10-19
summary: "Prerequisites, pinned toolchain, test pyramid, local cluster topologies, Makefile targets, Definition of Done."
phases: [all]
topics: [testing, makefile, toolchain, local-clusters, dod]
references: [02-instance-manager, 03-ha, 09-phases, ADR-016]
changelog:
  - {version: 0.5.0, date: 2026-10-19, change: "Pin verified Go toolchain versions for Phase 0 scaffold"}
  - {version: 0.4.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.3.0, date: 2026-10-16, change: "Specify DCO check in Phase 0 CI"}
  - {version: 0.2.0, date: 2026-10-16, change: "Set project home to kinarix/pgkeeper"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# 08 — Testing Strategy, Local Clusters, and Makefile Contract

## 1. Prerequisites on a developer machine
Only: `docker` (or compatible engine with ≥ 8 GB RAM / 4 CPU allotted), `go` (version from `go.mod`), `make`, `git`. **Everything else is installed by the Makefile into `./bin/`** with pinned versions. Linux and macOS, amd64 and arm64.

## 2. Pinned toolchain (verify & bump at Phase 0; record in Makefile variables)
| Tool | Variable | Snapshot (2026-10) | Pinned (verified 2026-10-19) |
|---|---|---|---|
| Go | `go.mod` | 1.26.x | go 1.26.0 (built with 1.26.4) |
| controller-runtime | `go.mod` | v0.25.x | v0.25.2 |
| controller-gen | `CONTROLLER_TOOLS_VERSION` | v0.22.x | v0.23.0 (k8s 0.37 deps, same as v0.22.x) |
| kubebuilder scaffold | — | v4.16 (scaffold once, then hand-maintained) | v4.16.0 |
| setup-envtest / envtest K8s | `ENVTEST_K8S_VERSION` | 1.36.x | 1.36.2 |
| golangci-lint | `GOLANGCI_LINT_VERSION` | v2.12+ | v2.15.0 |
| kind | `KIND_VERSION` | v0.33.x (default node 1.37.0; 1.34–1.36 images available) | |
| k3d | `K3D_VERSION` | latest v5.x — verify | |
| k3s image | `K3S_IMAGE` | `rancher/k3s:v1.36.x-k3s1` — verify | |
| kubectl | `KUBECTL_VERSION` | matches newest node | |
| kustomize | `KUSTOMIZE_VERSION` | v5.x | v5.8.3 |
| helm | `HELM_VERSION` | v3.x / v4 — verify | |
| chainsaw | `CHAINSAW_VERSION` | v0.2.15+ | |
| chaos-mesh | `CHAOS_MESH_VERSION` | verify | |
| WAL-G | `WALG_COMMIT` | pinned commit ≥ v3.0.8 incl. PG15+ base-backup protocol fix | |
| SeaweedFS | `SEAWEEDFS_IMAGE` | pinned digest | |
| fake-gcs-server, Azurite, atmoz/sftp, Dex | `*_IMAGE` | pinned digests | |
| Postgres images | `PG_IMAGES` | `postgres:16-trixie`, `postgres:17-trixie`, `postgres:18-trixie` (digest-pinned in CI) — verify Debian suite tags at phase start | |

## 3. Test pyramid
### 3.1 Unit (`make test-unit`, < 60 s, no network)
Pure logic: config rendering, managed-parameter validation, HBA rendering, SCRAM verifier, grant plan diff, failover candidate selection, lease timing math, cron next-run, log categorisation, statement redaction lexer, pod spec hash. Table-driven; `-race`; coverage gate 80 % on `internal/ha`, `internal/sqlplan`, `internal/config`.

### 3.2 Model / property tests (part of `make test-unit`)
- `pgregory.net/rapid` state-machine test of the HA protocol: simulated instances, the Lease voter and instance voters (03 §3), clocks with bounded drift, partitions (incl. one-sided), crashes, postmaster crashes/restarts while holding the lease (both `crashHandling` policies), voter restarts, operator restarts, voter-set changes with joint quorums. Checked properties: I1, I1a, I2, I4, I7 never violated; liveness: with a healthy majority and operator up, a primary exists within `leaseDuration + failoverDelay + 10 s` simulated.
- Property tests for grant diffing (applied ⊆ declared ∪ previously-applied), redaction (no literal survives).

### 3.3 envtest integration (`make test-envtest`, < 5 min)
Real kube-apiserver + etcd, **no** kubelet and **no** Postgres. IM client faked with a programmable fake. Covers: CRD validation (CEL rules — each rule has a positive and negative case), object generation, SSA drift repair, finalizers, status/conditions, switchover/failover state machines driven by fake IM responses, multi-namespace scoping.

### 3.4 IM integration (`make test-im`, < 10 min)
testcontainers-go, real `postgres:16/17/18` images with the IM binary bind-mounted, in-process fake Lease store. Covers 02 §10 and WAL-G against a SeaweedFS container.

### 3.5 End-to-end on kind / k3d (`make e2e`)
Chainsaw tests (`test/e2e/chainsaw/<phase>-<name>/`) for declarative flows; Go e2e (`test/e2e/go/`) for anything needing measurement or SQL assertions. Each test creates its own namespace; parallelism 4; artifacts (pod logs, CR yaml, events, IM status) dumped to `_artifacts/` on failure.

### 3.6 Chaos & ledger tests (`make e2e-chaos`)
Inspired by the 2026 Coroot split-brain study. A **ledger harness**:
- N writer pods hold long-lived connections to `<cluster>-rw` (deliberately no pool recycling) and insert rows with `bigserial` ids; after each acknowledged commit they record `(writer, id, payload, server_ip, timeline, ack_time)` in a separate **truth database** outside the cluster under test.
- Faults (Chaos Mesh): primary pod kill, primary network partition (from replicas, operator, API server; kubelet probes optionally allowed), node container stop (`docker stop kind-worker2`), API server unavailability, operator kill, clock skew on one node, IO latency on primary PVC, pod freeze (SIGSTOP on postmaster for > lease duration). In mode `Peers`, the fault/expected-outcome table F1–F16 of ADR-016 is the scenario list; "API server down" is expected to cause **no** fence.
- Checks after heal: (a) **no overlap** — no second where two servers acknowledged writes (I1 empirically); (b) **lost acked writes** count — must be 0 with `dataDurability: Required`, ≤ lag-bound otherwise; (c) **stolen ids** (id now belongs to another writer's row) — must be 0 with Required; (d) write-unavailability duration within target (03 §5.4, §7); (e) cluster returns to Healthy, all replicas streaming, timeline consistent.
- Results written to `_artifacts/chaos-report.json`; the report table is pasted into the PR for any change to `internal/ha` or IM lifecycle.

### 3.7 Upgrade tests (Phase 28)
Install previous operator release → create clusters → upgrade operator → verify rolling IM update with no write outage beyond switchover budget.

## 4. Local cluster topologies
### kind (`hack/kind/kind-config.yaml`)
- 1 control-plane + 3 workers (anti-affinity needs ≥ 3 nodes), node image digest-pinned via `KIND_NODE_IMAGE`.
- Local registry `kind-registry:5001` connected to the kind network (images pushed instead of `kind load` for speed; `kind load` path kept as fallback).
- Default CNI kindnet (supports NetworkPolicy in recent kind) — partition tests use Chaos Mesh, not NetworkPolicy.
- StorageClass: kind's `standard` (local-path, RWO, node-bound — exercises 03 §11).
- Matrix variable `KIND_K8S_VERSION ∈ {1.34, 1.35, 1.36, 1.37}`; 1.34 exercises the init-copy tools fallback (image volumes off by default there).

### k3d / k3s (`hack/k3d/k3d-config.yaml`)
- 1 server + 3 agents, k3s image pinned, Traefik disabled, built-in registry `k3d-registry.localhost:5002`.
- k3s ships flannel + kube-router NetworkPolicy and local-path provisioner.
- Purpose: second distro (different kubelet/containerd config) and resource-constrained edge-like environment.
- Optional NFS provisioner (`make k3d-nfs`) for RWX PVC backup-store tests.

### Test infrastructure (`make infra-up`, namespace `pgkeeper-test-infra`)
SeaweedFS (S3), fake-gcs-server, Azurite, SFTP server (generated host key, known_hosts Secret published), Dex (OIDC for dashboard), Prometheus (kube-prometheus minimal, optional `INFRA_PROMETHEUS=1`), Chaos Mesh (only with `make chaos-up`). Manifests in `hack/infra/`, all images digest-pinned.

## 5. Makefile contract
### 5.1 Requirements
1. `make help` (default goal) prints every target with its `## description`, grouped by `##@ Section` headers.
2. All tools installed to `$(LOCALBIN)=./bin` as versioned files (`bin/kind-v0.33.0`) with an unversioned symlink; re-running is a no-op. No `sudo`, no global installs, no `curl | sh`.
3. Every variable overridable from env (`?=`): `IMG_REGISTRY` (default `ghcr.io/kinarix`; local registries for kind/k3d via `images-load`), `IMG_TAG` (default `git describe --tags --dirty --always`), `CLUSTER_PROVIDER` (`kind`|`k3d`, default `kind`), `CLUSTER_NAME` (default `pgkeeper`), `KIND_K8S_VERSION`, `PG_VERSIONS` (default `16 17 18`), `E2E_FOCUS`, `E2E_PARALLEL`, `ARTIFACTS`.
4. Idempotent: `make cluster-up` on an existing cluster exits 0; `make cluster-down` on a missing one exits 0.
5. Fail fast with actionable messages (e.g. docker not running, insufficient memory).
6. CI uses the **same** targets (no logic in CI YAML beyond matrix variables).
7. Targets that need a cluster check `kubectl config current-context` matches the expected local context and refuse to run against anything else unless `ALLOW_NON_LOCAL=1` (prevents deploying test infra into a real cluster).
8. `make` targets must work offline after a first successful run (tools and images cached), except `docker-push` to remote registries.
9. Phase discipline: each phase's acceptance criteria are expressed as one Make target `make accept-pN` that runs exactly the tests that prove that phase (09-phases.md), so "done" is mechanical.

### 5.2 Target catalogue
```
##@ General
help                 Show this help
tools                Install all pinned tools into ./bin
doctor               Check prerequisites (docker resources, go version, ports)

##@ Development
fmt                  go fmt + goimports
vet                  go vet
lint                 golangci-lint run (incl. SQL-concatenation and sort-package depguard rules)
generate             controller-gen object (deepcopy)
manifests            controller-gen crd rbac webhook → config/crd, config/rbac
api-docs             Generate docs/api-reference.md from Go types
verify               generate+manifests+fmt then fail if git diff is non-empty
dco                  Check every commit in $(DCO_BASE)..HEAD has a DCO sign-off by its author (default DCO_BASE=origin/main)

##@ Test
test                 test-unit + test-envtest
test-unit            Unit + property tests (-race)
test-envtest         envtest integration (downloads envtest assets via setup-envtest)
test-im              Instance-manager integration against real Postgres containers (PG_VERSIONS)
cover                Coverage report with per-package gates

##@ Build
build                Build all binaries into ./bin (operator, instance, dashboard, kubectl plugin)
build-walg           Build static WAL-G from $(WALG_COMMIT)
docker-build         Build images: operator, tools (instance + wal-g), dashboard
docker-push          Push images to $(IMG_REGISTRY)
images-load          Push to local registry (or kind load / k3d image import)

##@ Local cluster
cluster-up           Create $(CLUSTER_PROVIDER) cluster + local registry (idempotent)
cluster-down         Delete it
kind-up / kind-down  Provider-specific variants
k3d-up / k3d-down
k3d-nfs              Install NFS provisioner (RWX) into k3d
infra-up             Deploy SeaweedFS, fake-gcs, Azurite, SFTP, Dex (+Prometheus if INFRA_PROMETHEUS=1)
infra-down
chaos-up / chaos-down  Install/remove Chaos Mesh

##@ Deploy
install              Apply CRDs only
uninstall            Delete CRDs (refuses if any PostgresCluster exists unless FORCE=1)
deploy               Deploy operator + dashboard with images from IMG_*
deploy-dev           deploy with debug logging, 1 replica, dashboard --auth=dev
undeploy
samples              Apply config/samples (1-, 3-instance clusters, roles, db, grants, backup store)
dev                  cluster-up + infra-up + install + docker-build + images-load + deploy-dev + samples
watch                Rebuild & redeploy on file change (operator only)

##@ E2E
e2e                  All chainsaw + Go e2e on current cluster
e2e-smoke            < 5 min subset (create, connect, scale, delete)
e2e-ha               Switchover, failover, pinning, rolling update
e2e-backup           Archiving, full/delta, schedules, retention, PITR (all store types available locally)
e2e-access           Roles, databases, grants, HBA, TLS
e2e-dashboard        API-level dashboard tests (Dex login, impersonation, SSE log tail) + Playwright smoke
e2e-chaos            Ledger harness under Chaos Mesh faults (long: ~45 min)
e2e-matrix           Loop KIND_K8S_VERSION × PG_VERSIONS (CI nightly)
accept-pN            Acceptance suite for phase N (see 09-phases.md)

##@ Operations helpers
psql                 psql into CLUSTER=<name> NS=<ns> (via kubectl exec, peer auth)
status               Summarise all PostgresClusters (kubectl get + IM status)
logs                 Tail operator logs; LOGS=instance CLUSTER=.. tails postgres JSON logs pretty-printed
dashboard            Port-forward dashboard to localhost:8443 and print URL
artifacts            Collect diagnostics bundle into $(ARTIFACTS)
clean                Remove ./bin, _artifacts, build outputs
```

### 5.3 CI (GitHub Actions or equivalent)
- PR: `dco` (first, cheap; `DCO_BASE` = the PR base commit) + `verify lint test test-im` + `e2e-smoke` on kind 1.36 / PG18 + `accept-p<N>` for phases touched.
- **DCO check (`make dco`)** — pure git, no network, no third-party app:
  - every non-merge commit in `$(DCO_BASE)..HEAD` must contain a trailer `Signed-off-by: <name> <email>` whose email equals the commit's **author** email (case-insensitive); co-author trailers don't count;
  - merge commits are skipped;
  - output lists each failing commit (short SHA, subject) and prints the fix: `git rebase --signoff $(DCO_BASE)` then force-push;
  - required status check on `main` via branch protection (set by an org admin), so unsigned commits can't be merged;
  - bot commits get no exemption — bots used by the repo (e.g. Dependabot) must be configured to sign off.
- Nightly: `e2e-matrix`, `e2e-chaos` on kind 1.37 and k3d.
- Release: `docker-build docker-push`, sign images (cosign), SBOM, Helm chart publish (Phase 28).

## 6. Definition of Done (every phase)
1. Code + unit tests + envtest (+ IM/e2e as listed in the phase).
2. `make verify lint test` green; `make accept-pN` green on kind **and** k3d.
3. Specs updated if behaviour differs from them (spec is the source of truth — update it in the same PR).
4. Sample manifests updated; `docs/api-changelog.md` updated for API changes.
5. For HA-affecting changes: model tests updated and a `e2e-chaos` subset run, report attached.
6. No TODOs without an issue reference; no skipped tests without a reason and issue.
