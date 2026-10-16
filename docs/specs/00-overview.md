# 00 — Overview, Challenged Requirements, Architecture, Decisions

> Project: **pgkeeper**, repo `github.com/kinarix/pgkeeper`, images under `ghcr.io/kinarix/`, CRD API group `pgkeeper.in` (baked into every CRD, label and annotation; the `pgkeeper.in` domain should be held by kinarix so no other project can claim the group).
> Status: design. Research snapshot taken **2026-10-15**. Every external version below must be re-verified at the start of the phase that first uses it.

## 1. Purpose

A Kubernetes operator that deploys and operates highly available PostgreSQL clusters declaratively:

| # | Requirement (as stated) | Where specified |
|---|---|---|
| R1 | CRD-based deployment | 01-api.md |
| R2 | Automatic reconciliation of CRD changes and drift | 07-reconciliation-and-tenancy.md |
| R3 | HA with WAL (streaming) replication | 03-ha.md |
| R4 | Automatic failover with minimal client impact; manual primary pinning | 03-ha.md §5–§8 |
| R5 | Standard open-source Postgres Docker images | 02-instance-manager.md §2 |
| R6 | Backups to S3 / FTP / GCS etc., PITR, incremental backups | 04-backup-restore.md |
| R7 | Health checks and a dashboard | 02 §6, 06-observability-dashboard.md |
| R8 | One controller manages many clusters across many namespaces | 07 §4 |
| R9 | Dashboard shows access logs etc. in real time | 06 §3–§5 |
| R10 | Access control and user accounts via CRDs | 05-access-control.md |
| R11 | Small incremental phases, tested locally on kind/k3s, Makefile-driven | 08-testing-and-makefile.md, 09-phases.md |

## 2. Challenged requirements (read before building)

These are places where the stated requirement is ambiguous, risky, or conflicts with another one. Each has a decision; revisit them consciously rather than drifting.

### C1. Build vs adopt — **[High Confidence]** CloudNativePG already covers most of R1–R8
CloudNativePG (CNPG, Apache-2.0, CNCF) is at 1.30.x (1.30.1 shipped Sept 2026) and implements CRD clusters, instance manager, lease-based primary election, primary isolation checks, backup plugins, managed roles and a Database CRD. Gaps vs this brief: FTP (nobody supports it, see C2), a Grant CRD, a built-in dashboard with live access logs, and running on *docker-library* images rather than CNPG's own operand images **[Maybe — verify CNPG compatibility with docker-library images before deciding]**.
**Decision: build — [ADR-015](../adr/015-build-to-close-existing-gaps.md).** pgkeeper exists to close gaps in CNPG and other existing operators; those gaps, parity gaps and known regressions are tracked in the ADR-015 gap ledger. The build deliberately borrows CNPG's proven patterns (instance manager as PID 1, Pods+PVCs instead of StatefulSets, lease for promotion).

### C2. FTP backups — **[Certain]** not supported by any mainstream Postgres backup engine
WAL-G supports S3, GCS, Azure, Swift, SSH and local filesystem; pgBackRest supports posix, S3, GCS, Azure and SFTP. Neither supports FTP. FTP is also plaintext, lacks atomic rename/overwrite semantics that WAL archiving relies on, and has no integrity checks.
**Decision:** support **SFTP** (via WAL-G's SSH storage) as the "file server" target. FTP is a non-goal. If an FTP-only appliance must be used, mount it via a filesystem gateway outside the operator's responsibility.

### C3. "Standard images" vs needing extra binaries — **[High Confidence]** solvable, with caveats
The official `postgres` image contains only PostgreSQL. HA, backup and log streaming need an agent and WAL-G. **Decision:** never modify the image; inject a static `pgkeeper-instance` binary and a static `wal-g` binary at pod start via a Kubernetes **image volume** (stable and default-on in Kubernetes 1.36, beta-default-on in 1.35) with an **init-container copy fallback** for older clusters. Caveats:
- Extensions not in the image (pgaudit, pgvector, …) need PG18+ `extension_control_path` + image volumes, or a custom image. PG16/17 users get only bundled contrib extensions.
- Debian variants only in v1: the image's `postgres` UID is 999 on Debian but 70 on Alpine. Alpine is a later, explicit addition.
- The official image changed `PGDATA` to a version-specific path from PG18 (`/var/lib/postgresql/18/docker`) and the volume to `/var/lib/postgresql`. The operator bypasses `docker-entrypoint.sh` entirely and owns the data path (see 02 §3).

### C4. "Automatic failover with minimal impact" — **[High Confidence]** unplanned failover cannot be impact-free
- Every failover drops in-flight transactions and open connections. "Minimal impact" is achievable for **planned** switchover (seconds, near-zero errors with a pooler) — not for unplanned failover (typically 15–30 s of write unavailability).
- With asynchronous replication, writes acknowledged by the old primary but not yet streamed are **lost** on failover (RPO > 0). Only synchronous replication bounds this.
- Split-brain is the real danger. A July 2026 chaos study (Coroot) showed a default CNPG cluster keeping an isolated old primary writable for **177 s** after its replacement was promoted, because promotion and fencing ran on two independent timers (`failoverDelay` vs a 180 s graceful-shutdown budget) and pooled client connections never reconnected.
**Decision:** a single primary **lease** is the only safety mechanism — a *quorum lease* granted by the Kubernetes Lease and the instances themselves ([ADR-016](../adr/016-quorum-lease.md)), so a healthy primary survives an API-server outage and runs on its own while the API server is up. The holder self-fences with an *immediate* stop (which also kills client sessions) strictly before the lease can be acquired by anyone else. Timers are derived from one another and validated (03 §3.4). Synchronous replication with `dataDurability: Required` is offered for zero acknowledged-write loss.

### C5. "Pin a primary via another CRD" — **[High Confidence]** two writers for one fact is a bug factory
A separate pin CRD and the cluster CRD would both try to decide who is primary, with no defined precedence and ordering races. **Decision:**
- *Pinning* (a standing preference) is a field: `PostgresCluster.spec.primary.pin` (`Preferred` or `Strict`).
- *Switchover* (a one-shot imperative action) is a CRD: `PostgresSwitchover`, so it has an audit trail, status and RBAC of its own.
- *After a failover* the operator records the new primary in a `PostgresPrimaryOverride`, which beats the pin until a human deletes it (acknowledgement → switchback). Precedence is fixed: override > pin > best candidate, and the operator alone writes `status.targetPrimary` ([ADR-017](../adr/017-primary-override.md)).
- If RBAC separation of pinning is required (e.g. only DBAs may pin), enforce it with a `ValidatingAdmissionPolicy` that restricts changes to `spec.primary` by user/group — not with a second CRD.

### C6. Dashboard scope — **[High Confidence]** do not build a metrics/log platform
Prometheus + Grafana is the standard for metrics; Loki/OpenSearch for log retention. **Decision:** the dashboard is a thin, read-mostly operational console: cluster topology, health, backups, switchover actions, and **live-tail** of logs (no storage, no search history). Long-term logs go to the existing log pipeline. Access logs can contain personal data (usernames, client IPs, statement text) — treat the live tail as sensitive (RBAC-gated, redaction option), relevant for India's DPDP Act obligations.

### C7. "Point-in-time restore" — in place or new cluster? — **[High Confidence]** in-place restore is a footgun
**Decision:** PITR always bootstraps a **new** cluster from a backup store. The new cluster must archive to a different path than its source (enforced), otherwise two timelines corrupt one archive. An in-place "rewind the production DB" is out of scope.

### C8. Language — Go (default) vs Rust
**Decision: Go [High Confidence it is the lower-risk choice]**: controller-runtime/kubebuilder are the reference operator stack (kubebuilder v4.16, controller-runtime v0.25.x, Go 1.26 as of Sept 2026), envtest, WAL-G is Go, and most operator prior art (CNPG, Zalando, PGO) is Go. Rust (kube-rs) is viable and a strong team skill, but the operator ecosystem (envtest, codegen, webhooks, testing tools) is thinner. Revisit only if the operator must share code with an existing Rust/kube-rs platform.

### C9. Multi-namespace control — blast radius
One operator for all namespaces means one bug or bad release affects every database. **Decision:** support three scopes — all namespaces, an explicit list, or a label selector — and allow running multiple operator installs with disjoint scopes (e.g. prod vs non-prod). See 07 §4.

## 3. Goals and non-goals

**Goals (v1)**
- PostgreSQL 16, 17, 18 on official Debian images; PG19 added after GA (PG19 was at beta 4 in Sept 2026; GA expected ~Oct 2026).
- 1..N instances, streaming replication, async or quorum-sync.
- Lease-based safe failover; planned switchover; pinning; primary-aware rolling updates.
- WAL-G backups: continuous WAL archiving, full + delta (incremental) base backups, schedules, retention, PITR into a new cluster; S3 (and S3-compatible), GCS, Azure Blob, SFTP, PVC filesystem.
- CRDs for roles, databases, grants; TLS everywhere; drift repair inside and outside Postgres.
- Prometheus metrics, structured logs, a dashboard with OIDC login and live log tail.
- Kubernetes 1.34–1.37; fully testable on kind and k3d (k3s) on a laptop.

**Non-goals (v1)** — each may become a later phase:
- Major version upgrades (`pg_upgrade`). The PGDATA layout is chosen so `pg_upgrade --link` is possible later.
- Volume-snapshot backups; logical replication management; sharding; cross-Kubernetes-cluster replica clusters.
- FTP (C2); Alpine images (C3); in-place PITR (C7).
- Native PG17 `pg_basebackup --incremental` engine (designed as a pluggable engine, not built in v1 — see 04 §8).

## 4. Architecture

```
                         ┌─────────────────────────── operator namespace ───────────────────────────┐
                         │  pgkeeper-operator (Deployment, 2 replicas, leader-elected)               │
                         │   controllers: Cluster, Switchover, Role, Database, Grant,               │
                         │                BackupStore, Backup, ScheduledBackup                       │
                         │  pgkeeper-dashboard (Deployment) ── OIDC login, K8s impersonation         │
                         └──────────────┬───────────────────────────────┬───────────────────────────┘
                     watch/SSA K8s objs │                               │ mTLS (operator CA)
                                        ▼                               ▼
   ┌──────────────────────── application namespace (e.g. team-a) ──────────────────────────────────┐
   │ PostgresCluster "orders"                                                                       │
   │  Lease orders-primary  (holder = orders-1)                                                     │
   │  Services: orders-rw ─► role=primary   orders-ro ─► role=replica   orders-r ─► any             │
   │                                                                                                │
   │  Pod orders-1 (primary)          Pod orders-2 (replica)           Pod orders-4 (replica)       │
   │  ┌───────────────────────────┐   ┌──────────────────────────┐    ┌──────────────────────────┐ │
   │  │ container: postgres       │   │ same                     │    │ same                     │ │
   │  │ image: postgres:18.x      │   │                          │    │                          │ │
   │  │ PID1: pgkeeper-instance ──┼─► │ streams WAL from -1      │    │ streams WAL from -1      │ │
   │  │   └─ postmaster           │   │                          │    │                          │ │
   │  │ /pgkeeper (image volume): │   └──────────────────────────┘    └──────────────────────────┘ │
   │  │   pgkeeper-instance, wal-g│                                                                │
   │  └────────────┬──────────────┘                                                                │
   │       PVC orders-1 (PGDATA)   PVC orders-1-wal (optional)                                      │
   └───────────────┼────────────────────────────────────────────────────────────────────────────────┘
                   │ wal-g wal-push / backup-push
                   ▼
        Backup store: S3 | GCS | Azure | SFTP | PVC
```

### Components
| Component | Binary | Runs as | Responsibility |
|---|---|---|---|
| Operator | `pgkeeper-operator` | Deployment in operator ns | Reconciles CRDs into Pods/PVCs/Services/Secrets/Lease/PrimaryOverrides; failover *policy* (who should be primary); orchestrates switchover, rolling updates, backups; writes all CR status. |
| Instance manager (IM) | `pgkeeper-instance` | PID 1 inside every Postgres container | initdb/clone/restore; renders config; supervises postmaster; holds/renews the primary lease and self-fences; serves probes, status API, metrics; runs WAL-G; parses and re-emits Postgres logs as JSON. |
| Dashboard | `pgkeeper-dashboard` | Deployment in operator ns | OIDC login; reads CRs and pod logs through K8s API **impersonating the user**; creates Switchover/Backup CRs on the user's behalf. |
| Tools image | `pgkeeper-tools` | OCI image, mounted as image volume | Holds static `pgkeeper-instance` and `wal-g` binaries. |
| kubectl plugin (later) | `kubectl-pgkeeper` | user workstation | status, psql, switchover, backup shortcuts. |

### Division of authority (the core design rule)
- **Lease = safety.** At most one instance may run Postgres read-write: the one holding valid grants that form a sustain quorum of the quorum lease (the `<cluster>-primary` Lease **or** enough peer instances, 03 §3). The IM enforces this locally, without needing the operator — and, in mode `Peers`, without needing the API server.
- **Operator = liveness and policy.** The operator decides *which* instance should be primary (`status.targetPrimary`) and when. If the operator is down, failover is delayed, never unsafe.
- **Status has one writer.** Only the operator writes CR `status`. IMs expose state over HTTPS; the operator pulls it.
- **Pods and PVCs, not StatefulSets.** StatefulSet ordered rollouts and ordinal identity fight primary-aware updates (update replicas first, switch over, then the old primary). The operator manages Pods and PVCs directly, with monotonically increasing instance serials that are never reused.

## 5. Decision log
Architecture decisions live in [`docs/adr/`](../adr/README.md), one file per ADR (index in its README). Specs reference them as `ADR-NNN`.

## 6. Spec index
- 01-api.md — every CRD, fields, validation, status, examples
- 02-instance-manager.md — PID 1 behaviour, bootstrap, config, probes, HTTP API, logs
- 03-ha.md — replication, lease protocol, fencing, switchover, failover, sync replication, pinning, rolling updates
- 04-backup-restore.md — stores, archiving, full/delta backups, schedules, retention, PITR
- 05-access-control.md — roles, databases, grants, pg_hba, TLS, operator/IM RBAC
- 06-observability-dashboard.md — metrics, logs, access logs, alerts, dashboard
- 07-reconciliation-and-tenancy.md — reconcile loop rules, drift, finalizers, multi-namespace, operator HA
- 08-testing-and-makefile.md — test pyramid, local clusters, chaos/ledger testing, Makefile contract
- 09-phases.md — 29 small phases with acceptance criteria
- 10-glossary.md — every term, with intuition and examples
- 11-ha-scenarios.md — what happens in each failure/maintenance scenario, with diagrams (explanatory; 03 and ADR-016 are normative)
- ../adr/ — architecture decision records (ADR-001 …)
