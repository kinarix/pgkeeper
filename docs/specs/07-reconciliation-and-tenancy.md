---
id: 07-reconciliation-and-tenancy
title: "07 — Reconciliation, Drift, Lifecycle, Multi-Namespace Tenancy, Operator HA"
type: spec
status: design
version: 0.4.0
updated: 2026-10-19
summary: "Reconcile loop rules, watched objects and drift repair, deletion lifecycle, watch scopes, operator HA, flags."
phases: [P1, P3, P4, P5, P15, P26]
topics: [reconcile, drift, lifecycle, tenancy, operator-ha]
references: [03-ha, 06-observability-dashboard, ADR-004, ADR-018, ADR-022]
changelog:
  - {version: 0.4.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.3.0, date: 2026-10-16, change: "Use pgkeeper.in as the CRD API group"}
  - {version: 0.2.0, date: 2026-10-16, change: "Resolve open spec review findings"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# 07 — Reconciliation, Drift, Lifecycle, Multi-Namespace Tenancy, Operator HA

## 1. Reconcile loop rules (all controllers)
1. **Level-triggered and idempotent.** Each reconcile reads current state and converges one step; it must be safe to run any number of times, concurrently with an IM, and after a crash at any line.
2. **No blocking waits** inside reconcile. Long operations (backup, switchover, restore) are state machines persisted in CR status; reconcile returns `RequeueAfter` (typical 2–10 s) while waiting.
3. **Server-side apply** with field manager `pgkeeper-operator` for every owned object. Apply the full desired object each time; never read-modify-write a whole object. Use `ForceOwnership` only for fields the operator exclusively owns. This also gives drift repair for free: a manual edit to an operator-owned field is overwritten on the next apply.
4. **Owner references** on every generated object → the cluster (controller=true). Exceptions: PVCs get an owner ref only when `deletionPolicy: Delete`; otherwise label-only so they survive cluster deletion.
5. **Status writes** via status subresource, only when changed (deep-equal check), with `observedGeneration`. Conditions via `meta.SetStatusCondition`.
6. **Events** (`record.EventRecorder`) for every state transition a human would care about: Created, ScaledUp, SwitchoverStarted/Completed, FailoverStarted/Completed, OverrideCreated/Updated, FailoverAcknowledged, SwitchbackStarted, FenceApplied, DriftCorrected, BackupCompleted/Failed, RestoreCompleted, UnsupportedChange, InstanceUnreachable, DiskPressureWarning/Critical, BackendOOMKilled, NotificationDropped. HA and storage events are also sent to the notification webhook if configured (06 §2.5).
7. **Errors:** wrap with context; transient → return error (rate-limited requeue); permanent spec problems → condition + no requeue spam (requeue after 5 min).
8. **Instance health is pulled** (ADR-018): IM `/v1/status` every 5 s, jittered; 3 consecutive failures → instance `role: unknown`, not ready, event `InstanceUnreachable`. Never a failover trigger on its own (03 §5.1).
9. **Context deadlines** on every external call: K8s API (inherit), IM calls (default 10 s, backup start 30 s), SQL (IM side).
10. **Concurrency:** `MaxConcurrentReconciles` = 10 for Cluster, 5 for others (flags). Per-cluster serialization is guaranteed by controller-runtime's workqueue (same key never processed concurrently).
11. **Predicates:** ignore status-only updates on own kinds (`GenerationChangedPredicate` + annotation changes); owned-object watches use `Owns()`; Pods also trigger on readiness/label/deletion changes.

## 2. What is watched (and therefore drift-repaired)
| Watched | Trigger | Repair |
|---|---|---|
| PostgresCluster | spec/annotation change | full reconcile |
| Pods, PVCs, Services, Secrets, ConfigMaps, SAs, Roles, RoleBindings, PDBs, Leases (owned) | any change/deletion | re-apply / recreate (Pods recreated only via the rollout logic; a manually deleted primary pod = failover path) |
| Nodes | Ready transitions | failure detection, stranded instances (03 §11) |
| PostgresBackupStore | change | re-render WAL-G config hash → IMs reload |
| Secrets referenced by Roles/Stores/notifications/TLS `UserProvided` (not owned) | change (metadata-only watch) | field indexers on the referencing fields → enqueue owners; data read uncached (§4.3) |
| Periodic resync | every `--sync-period` (default 10 min, jittered) | catches in-database drift (roles/grants/db), ALTER SYSTEM on PG16, slots |

**In-Postgres drift** (things K8s watches cannot see) is checked by:
- IM: config hash, `postgresql.auto.conf` emptiness, HBA file hash, slot set (every 30 s, reported in status → operator corrects).
- Role/Database/Grant controllers on resync.

## 3. Lifecycle & deletion
- Cluster creation order: Secrets/CA → SA/RBAC → Lease (pre-created, empty holder) → ConfigMap → Services → PVC → Pod 1 → wait primary → replicas.
- **Deletion** (finalizer): (1) set `phase: Deleting`; (2) delete Switchover/Backup children; (3) stop pods replicas-first, primary last (fast); (4) if `deletionPolicy: Delete` delete PVCs and generated Secrets; else leave PVCs labelled `pgkeeper.in/orphaned-from=<uid>` (re-creating a cluster with the same name does **not** silently adopt them — `bootstrap.adoptPVCs: true` is a later feature); (5) remove finalizer. Backups in stores are **never** deleted on cluster deletion.
- Role/Database/Grant deletion when the cluster is already gone: finalizer removed without SQL (log + event).
- Operator uninstall must not delete clusters: CRDs are installed separately from the operator Deployment (`make install` vs `make deploy`), and Helm chart sets `helm.sh/resource-policy: keep` on CRDs.

## 4. Multi-namespace tenancy
### 4.1 Watch scopes (flag `--watch-scope`)
| Mode | Flags | RBAC |
|---|---|---|
| `all` (default) | — | ClusterRole + ClusterRoleBinding |
| `list` | `--watch-namespaces=a,b,c` | Role+RoleBinding per namespace (kustomize overlay generates), cache restricted via `cache.Options.DefaultNamespaces` |
| `selector` | `--watch-namespace-selector=pgkeeper.in/managed=true` | ClusterRole (needs namespace list/watch); controller filters events by namespace label (namespace informer + predicate) |

### 4.2 Multiple operator installs
- Each install has an `--instance-id` (default `default`). CRs may carry label `pgkeeper.in/operator-instance=<id>`; an operator ignores CRs labelled for another id and, in `all` mode, ignores unlabeled CRs if `--require-instance-label` is set. Prevents two operators fighting over one cluster.
- CRDs are shared cluster-wide; CRD version upgrades are coordinated by the platform team (documented runbook).

### 4.3 Fairness and isolation
- Per-namespace work isn't throttled in v1, but per-cluster backoff (rate-limited queue) prevents a broken cluster from starving others.
- Informer caches: only labelled objects (`app.kubernetes.io/managed-by=pgkeeper`) are cached in full for Pods/Secrets/ConfigMaps/PVCs (`cache.ByObject` label selectors) — memory stays bounded in big clusters (lesson: operators caching all Secrets have crash-looped in large Helm-heavy clusters).
- **User-referenced Secrets** (role passwords, store credentials, webhook URLs, `UserProvided` TLS — unlabelled, owned by the user) are never in the full cache (ADR-022): the operator watches Secrets **metadata-only** (`PartialObjectMetadata`, a few hundred bytes each, no data) in watched namespaces to see changes, maps them to referencing CRs via field indexers, and reads the data with an uncached `GET` (APIReader) only when reconciling a referencing CR. The operator never adds labels to user Secrets (GitOps tools would fight it).
- Scale target for v1: 200 PostgresClusters / 600 instances per operator install, reconcile p99 < 2 s at steady state (load-tested in Phase 26 with fake IMs).

## 5. Operator HA
- Deployment, 2 replicas, `leader-elect=true` (Lease `pgkeeper-operator-leader` in operator ns), PDB minAvailable 1, anti-affinity.
- Leader loss = reconcile pause of ≤ lease duration (15 s). Postgres primaries are unaffected because they renew their *own* leases (ADR-004/005).
- Operator upgrade: new version must tolerate state written by previous minor; tools image version change triggers a rolling update of IMs (03 §9) — rate-limited fleet-wide by `--max-concurrent-cluster-rollouts` (default 5).
- Health endpoints: `/healthz`, `/readyz` (cache synced).

## 6. Configuration of the operator (flags / env)
`--watch-scope`, `--watch-namespaces`, `--watch-namespace-selector`, `--instance-id`, `--sync-period`, `--tools-image`, `--tools-delivery`, `--max-concurrent-reconciles-*`, `--max-concurrent-cluster-rollouts`, `--leader-elect`, `--metrics-bind-address`, `--health-probe-bind-address`, `--log-level`, `--notify-webhook-secret` (operator-wide fallback webhook, 06 §2.5). There is deliberately no default Postgres image flag: `spec.image` is required so upgrades are always an explicit spec change.
