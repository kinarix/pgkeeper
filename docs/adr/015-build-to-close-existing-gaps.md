# ADR-015 — Build pgkeeper to close gaps in existing Postgres operators

- Status: Accepted
- Date: 2026-10-15
- Related: 00-overview C1; ADR-003, ADR-004, ADR-010

## Context
Challenged requirement C1 found that CloudNativePG (CNPG 1.30.x, Apache-2.0, CNCF) already covers most of R1–R8. C1 allows a build only if the reason is written down in an ADR; otherwise the default was to adopt CNPG and build only the dashboard and Grant CRD on top.

The project owner's reason: pgkeeper exists **to address the gaps in CNPG and other existing solutions as much as possible**. This is C1 condition (c), a gap being a hard requirement, applied to the project as a whole rather than one feature.

## Decision
Build pgkeeper as a standalone operator. Keep borrowing CNPG's proven patterns (instance manager as PID 1, Pods+PVCs instead of StatefulSets, lease before promotion) rather than reinventing them.

Since closing gaps is the reason the project exists, the gaps are tracked as a deliverable in the **gap ledger** below.

## Rules that follow from this decision
1. **Every differentiator claim needs proof.** Each ledger row names the phase and the acceptance test that demonstrates it. A claim without a passing test is not made in docs or release notes.
2. **Regressions are defects.** Where the spec handles something worse than an existing operator already does, it is a must-fix or an explicit, documented non-goal in this ledger. It is never left implicit.
3. **Verify, don't remember.** Competitor status is re-checked against upstream docs at the start of each phase that touches a row. Update the "checked" date. Rows marked *unverified* must not be used in external claims.
4. **Parity gaps get a decision.** Features existing operators have and pgkeeper v1 does not are classified as `parity-later` (with a phase) or `never` (with a reason) before Phase 28.

## Gap ledger

### Surveyed operators (checked 2026-10-15 against upstream docs)
| Short name | Project | Version surveyed | HA engine | Backup engine | Operand image |
|---|---|---|---|---|---|
| CNPG | CloudNativePG | 1.30 (devel docs) | Own instance manager + primary lease | Barman Cloud plugin (CNPG-I); in-core `barmanObjectStore` deprecated since 1.26 | Own images (`minimal`/`standard`/`system`); "any compatible image" with `initdb`, `postgres`, `pg_ctl`, `pg_controldata`, `pg_basebackup` on PATH and a working locale |
| Zalando | zalando/postgres-operator | v2.0.3 (README), PG 14–18 | Patroni (inside Spilo) | WAL-E (default) / WAL-G, via Spilo | Spilo required |
| PGO | Crunchy Postgres for Kubernetes (PGO) | 6.0 (docs) | Patroni | pgBackRest | Crunchy images (Developer Program terms), or self-built from the `components` dir |

Cell legend: **No** = docs reviewed, feature absent or explicitly unsupported. **Not found** = not in the pages reviewed; absence not confirmed. **Partial** = covers part of the gap (explained).

### A. Differentiators (gaps in existing solutions that pgkeeper closes)
| # | Gap | CNPG | Zalando | PGO | pgkeeper answer | Phase | Proof |
|---|---|---|---|---|---|---|---|
| A1 | Declarative per-object grants (table/sequence/function/schema privileges, default privileges, revoke what we granted) | **No** — Database CRD manages db, extensions, schemas, FDWs, servers; only grants are `USAGE` on FDWs/servers. Roles: attributes + `inRoles` membership | **Partial** — `preparedDatabases` creates `<db>_owner/_reader/_writer` roles with default privileges; "fine-grained data access control … must be set up by the user"; never revokes | **No** — `spec.users` sets role attributes + database access; "does not delete Postgres objects or revoke permissions" | `PostgresGrant` (05 §3) | P17 | `accept-p17` |
| A2 | Operational web console with live Postgres/access logs, authorized by the user's own RBAC | **No** — no web UI in the feature list (kubectl plugin, Grafana) | **Partial** — UI creates/edits/clones/deletes manifests and shows *operator* logs; no Postgres or access logs; auth model not found | **Partial** — pgAdmin 4 (SQL client) and Grafana via pgMonitor; no operational console or live logs | Dashboard v1/v2 with impersonation (ADR-010, ADR-011) | P22, P24, P25 | `accept-p24`, `accept-p25` |
| A3 | Runs on unmodified official `postgres` images | **Probably not a gap** — stated requirements (binaries on PATH, locale, no entrypoint needed) appear to be met by docker-library images; untested. Default UID differs (CNPG images 26 vs official Debian 999; `postgresUID` configurable) | **Yes, gap** — Spilo required | **Yes, gap** — Crunchy images, or rebuild from their components | Tools injected via image volume / init copy (ADR-003) | P0, P3 | `accept-p0`, `accept-p3` on `postgres:16/17/18-trixie`; **plus** a Phase 0 spike running CNPG on `postgres:18-trixie` to settle the CNPG cell |
| A4 | Isolated old primary keeps accepting writes after a replacement is promoted | **Partial** — 1.27+ isolation check (liveness fails only when the API server **and** all peers are unreachable, then kubelet restart); that path is a **smart** shutdown letting open sessions commit for up to `smartShutdownTimeout` (default 180 s) — the window from the Coroot study. Configurable to 0 (fast) | Not found — Patroni leader key in a Kubernetes DCS; fencing timing not verified | Not found — Patroni; DCS and fencing timing not verified | Derived timers, CEL-enforced margin, **immediate** self-fence by default (ADR-004) | P8, P10 | Ledger chaos run: overlap = 0 s with defaults |
| A5 | SFTP backup target with enforced host keys | **No** — Barman Cloud plugin: S3(-compatible), Azure Blob, GCS | **Partial** — Spilo enables WAL-G for "Azure and SSH", not exposed as a documented operator option; host-key enforcement not found | **No** — repo types `azure`, `gcs`, `s3`, `volume` | WAL-G SSH storage, `knownHostsSecretRef` required (04 §3.1) | P18 | `accept-p18` (SFTP) |
| A6 | Redaction of statement literals in emitted logs (DPDP/GDPR) | Not found | Not found | Not found | Pure-Go literal-stripping redaction (06 §3.3) | P22 | Property test + `accept-p22` |
| A7 | Several operator installs with disjoint scopes in one Kubernetes cluster | **No** — "does NOT currently support running multiple operators on the same cluster" (namespaced workaround, shared CRDs, no upgrade guarantee) | **Yes, has it** — `CONTROLLER_ID` + `acid.zalan.do/controller` annotation (same model as ours) | Partial — namespace restriction; multiple installs not found | `--instance-id`, watch scopes (07 §4) | P26 | `accept-p26` |
| A8 | Primary keeps accepting writes during a control-plane (API-server) outage, while staying safe in one-sided partitions | **Partial** — 1.27+ isolation check keeps the primary up while it can reach peers; the fence path is a smart shutdown (see A4) | Not found — Patroni `failsafe_mode` not verified | Not found — Patroni `failsafe_mode` not verified | Quorum lease: sustain on K8s Lease *or* peers, promote with both (ADR-016) | P10b | Chaos faults F1–F4, F8 in ADR-016 |

Differentiation summary: A1 and A2 are gaps in all three. A4–A6 are gaps vs CNPG and likely vs the others (unverified cells). A3 is a gap vs Zalando and PGO but probably not CNPG. A7 is a gap vs CNPG only. A8 is new with ADR-016; the Zalando/PGO cells need the Patroni docs before any claim.

### B. Parity (existing solutions have it)
| # | Feature | CNPG | Zalando | PGO | pgkeeper v1 | Classification |
|---|---|---|---|---|---|---|
| B1 | Password delivered to Postgres as SCRAM verifier (no plaintext in SQL) | Yes — operator-side SCRAM encoding; logging suppressed during role SQL | **No** — md5 by default, `scram-sha-256` via `password_encryption`; delivery not found | Yes — `verifier` key in the user Secret | ADR-014, P15 | **Parity in v1** (was listed as a differentiator; it is not) |
| B2 | Major version upgrade | Yes — offline in-place | Yes — in-place (Spilo ≥ 13), "global upgrade of all clusters" | Yes — `PGUpgrade` CRD, `pg_upgrade`, requires full shutdown | Non-goal; PGDATA layout allows `pg_upgrade --link` later | Open |
| B3 | Volume-snapshot backups | Yes | Not found | Yes — `spec.backups.snapshots` | Non-goal | Open |
| B4 | Standby / replica clusters (incl. across Kubernetes clusters) | Yes (incl. delayed replicas) | Yes — from S3/GCS archive or remote host; manual promotion only | Yes — within and across Kubernetes clusters | Non-goal | Open |
| B5 | Tablespaces | Yes (incl. temporary) | Not found | Experimental, feature gate `TablespaceVolumes` | Not specified | Open |
| B6 | Hibernation / shutdown | Yes | Not found | Yes — `spec.shutdown` | Annotation reserved, "later phase" (03 §10) | Open |
| B7 | Import / clone from another cluster or database | Yes — offline and online import | Yes — clone from S3 or a running cluster | Yes — `spec.dataSource` | Only PITR from our own backups (04 §7) | Open |
| B8 | FDWs / foreign servers declaratively | Yes | No | No | Not specified | Open |
| B9 | Logical replication management | Partial — Subscription for online import | Not found | Not found | Non-goal | Open |
| B10 | Connection pooler (PgBouncer) | Yes — `Pooler` | Yes | Yes | Optional Phase 27 | parity-later (P27) |
| B11 | Logical (dump) backups | Not found | Yes — `pg_dumpall` CronJob to S3/GCS | Not found | Not specified | Open |
| B12 | Multiple backup destinations per cluster | Not found | Not found | Yes — up to 4 repos | One `storeRef` | Open |
| B13 | Popular non-contrib extensions on PG16/17 (PostGIS, pgvector, TimescaleDB, pgaudit, pg_cron …) | Via own images / image-volume extensions | Bundled in Spilo | Bundled in Crunchy images | PG16/17: contrib only (cost of A3); PG18+: image-volume extensions | Open — direct trade-off of A3 |
| B14 | Namespace-scoped watch | Yes — `WATCH_NAMESPACE` | Yes — `WATCHED_NAMESPACE` | Yes | `all` / `list` / `selector` (07 §4) | Parity in v1 (P26) |
| B15 | Signed images, SBOM, provenance | Yes — signed, SBOM + provenance, weekly CVE rebuilds | Not found | Not found | Phase 28 | parity-later (P28) |

### C. Known regressions in the current spec (must-fix or documented non-goal)
| # | Issue | Spec | Status |
|---|---|---|---|
| C1 | An API server outage fences every primary in the fleet | 03 §3 | **Resolved by ADR-016** (quorum lease, Phase 10b). Until `spec.ha.quorum: Peers` becomes the default, clusters on `KubernetesLease` keep this behaviour |
| C2 | `archive_mode = on` can leave an archive gap at failover | 04 §4 | **Resolved by ADR-020** (`archive_mode = always` + dedup) |
| C3 | `pg_rewind` cannot connect under the rendered HBA / role privileges | 03 §5.5, 05 §4 | **Resolved** (dedicated `pgkeeper_rewind` role with cert auth and minimal grants, 05 §1.4) |

### Sources (2026-10-15)
- CNPG: `cloudnative-pg.io/docs/devel` (feature overview, container images, instance manager, declarative role management, declarative database management, operator configuration); `cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/`.
- Zalando: `github.com/zalando/postgres-operator` README; `postgres-operator.readthedocs.io/en/latest/` (user guide, operator UI, administrator guide).
- PGO: `github.com/CrunchyData/postgres-operator` README; `access.crunchydata.com/documentation/postgres-operator/latest/` (user management tutorial + architecture, major version upgrade, tablespaces, backups, PostgresCluster CRD reference 5.8.x).
- Not reviewed: Patroni DCS/failsafe docs (A4 Zalando/PGO cells), Zalando UI auth, PGO 6.0 release notes. Fill these before using A4 against Zalando/PGO.

## Consequences
- Scope pressure: the ledger makes parity gaps visible, which will invite scope growth. Rule 4 forces an explicit decision instead of silent creep. Phase discipline (09-phases.md) still applies.
- Higher bar on HA: because A4 is a headline claim, any change to `internal/ha` or the lease loop keeps requiring model tests and a ledger chaos report (CLAUDE.md, 08 §3.6).
- The 2026-10-15 survey already moved SCRAM verifiers from differentiator to parity (B1) and made A3 doubtful against CNPG. If the Phase 0 spike shows CNPG runs on official images, and/or CNPG closes the A4 window by default, the case for building rests on A1, A2, A5, A6, A7, A8. Re-evaluate this ADR if the differentiators shrink to only A1/A2, which C1 notes could be built on top of CNPG.
- A3 has a direct cost (B13): users of PG16/17 lose the non-contrib extensions every surveyed operator bundles.
