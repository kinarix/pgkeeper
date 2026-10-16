# 09 — Implementation Phases

Rules
- One phase per branch/PR series. Do not start phase N+1 until `make accept-pN` passes on kind **and** k3d.
- Each phase is deliberately small (target: 1–4 working days). If a phase grows, split it (N → Na, Nb) and update this file first.
- "Acceptance" lists what `make accept-pN` runs. Tests named here must exist by the end of the phase.
- Track status in the table below (update in the PR that completes a phase).

| Phase | Title | Status |
|---|---|---|
| 0 | Repo, toolchain, Makefile, local clusters | ☐ |
| 1 | API skeleton: PostgresCluster types + CEL | ☐ |
| 2 | Instance manager v0 (outside K8s) | ☐ |
| 3 | Single-instance cluster on K8s | ☐ |
| 4 | Configuration management & drift repair | ☐ |
| 5 | IM status API (mTLS) & cluster status | ☐ |
| 6 | Streaming replicas & scaling | ☐ |
| 7 | Probes hardening, PDBs, scheduling | ☐ |
| 8 | Primary lease & fencing primitives | ☐ |
| 9 | Planned switchover (PostgresSwitchover) | ☐ |
| 10 | Automatic failover & rejoin (pg_rewind) | ☐ |
| 10b | Quorum lease (peer voting) | ☐ |
| 11 | Synchronous replication | ☐ |
| 12 | Primary pinning | ☐ |
| 13 | Primary-aware rolling updates | ☐ |
| 14 | TLS (client, replication, rotation) | ☐ |
| 15 | PostgresRole | ☐ |
| 16 | PostgresDatabase | ☐ |
| 17 | PostgresGrant | ☐ |
| 18 | Backup stores & continuous WAL archiving | ☐ |
| 19 | On-demand base backups (full + delta) | ☐ |
| 20 | Scheduled backups & retention | ☐ |
| 21 | Restore & PITR | ☐ |
| 22 | Logging pipeline & access logs | ☐ |
| 23 | Metrics, alerts, Grafana | ☐ |
| 24 | Dashboard v1 (read-only, live logs) | ☐ |
| 25 | Dashboard v2 (actions) | ☐ |
| 26 | Multi-namespace scoping, operator HA, scale test, NetworkPolicy | ☐ |
| 27 | Connection pooler (optional) | ☐ |
| 28 | Release hardening | ☐ |

---

## Phase 0 — Repo, toolchain, Makefile, local clusters
**Goal:** a clean machine with docker+go+make can run `make dev` and get an empty operator running on kind and k3d.
**Scope:** kubebuilder v4 scaffold (`--domain pgkeeper.io --repo github.com/kinarix/pgkeeper`, repo layout per CLAUDE.md), multi-binary layout (`cmd/operator`, `cmd/instance`, `cmd/dashboard`), Makefile with all **General/Development/Build/Local cluster/Deploy** targets (08 §5) — E2E targets as stubs that exit 0 with "not yet implemented"; `hack/kind`, `hack/k3d` configs with local registries; tools image Dockerfile (`FROM scratch`) containing a placeholder `pgkeeper-instance` with a working `install --to` subcommand (init-copy has no shell, 02 §2), the image-volume node-capability table (minimum kubelet + containerd/CRI-O versions) verified and pinned and WAL-G built from pinned commit (`make build-walg`); golangci-lint config incl. depguard; CI workflow running `verify lint test`.
**Out:** any CRD logic.
**Acceptance (`accept-p0`):** `make doctor tools verify lint test`; `make cluster-up` twice (idempotent) for both providers; `make docker-build images-load deploy`; operator pod Ready; `wal-g --version` runs inside a `postgres:18` container with the tools image mounted as image volume (kind 1.36) **and** via init-copy (kind 1.34); `make cluster-down` twice.

## Phase 1 — API skeleton
**Goal:** `PostgresCluster` v1alpha1 Go types for the **subset** needed through Phase 7 (instances, image, uid/gid, storage, walStorage, resources, postgresql.parameters/hba, bootstrap.initdb, scheduling, services, pdb, deletionPolicy) with OpenAPI defaults, CEL rules, printer columns; controller that only sets `observedGeneration` and `Ready=False reason=NotImplemented`.
**Acceptance:** envtest: every CEL rule positive+negative (managed-parameter rejection, storage shrink rejection, immutables, instances bounds); `kubectl apply` of `config/samples/*` succeeds on kind.

## Phase 2 — Instance manager v0 (outside Kubernetes)
**Goal:** `pgkeeper-instance run` as PID 1 in the official image: initdb, render config (conf.d layout, pg_hba), start/stop postmaster, signal handling, zombie reaping, crash restart backoff, `/healthz` `/readyz` `/startupz`, FIFO jsonlog → stdout wrapper (no categorisation yet). Cluster facts come from a local YAML file (flag) instead of the K8s API.
**Acceptance (`test-im`):** for PG 16/17/18: bootstrap, connect via socket, SIGTERM → fast stop within budget, kill postmaster → restarted, PID-1 reaping test, FIFO logs appear on stdout as JSON, `allow_alter_system=off` on 17/18 (ALTER SYSTEM fails), auto.conf emptied on 16.

## Phase 3 — Single-instance cluster on Kubernetes
**Goal:** `instances: 1` cluster comes up and is connectable.
**Scope:** operator generates Secrets (app owner password), SA/Role/RoleBinding for IM, pre-created Lease (unused yet), ConfigMap with rendered config + hash, headless + rw Service, PVC, Pod (tools delivery auto), securityContext, probes. IM reads cluster CR + ConfigMap (replaces Phase 2 YAML file). Finalizer + deletionPolicy.
**Acceptance:** chainsaw `p3-single-instance`: create → Ready within 3 min → `psql` via `-rw` service with app Secret (sslmode=disable allowed until Phase 14 — HBA temporarily allows `host` for pod CIDR, flagged as TODO(P14)) → delete with Retain keeps PVC → delete with Delete removes PVC. Runs on PG 16/17/18.

## Phase 4 — Configuration management & drift repair
**Goal:** spec changes and manual tampering converge.
**Scope:** parameter changes → reload; `pending_restart` detection → the single instance is restarted via a temporary pod-annotation handshake (`pgkeeper.io/restart-requested`, read by the IM; replaced by `/v1/restart` in Phase 5); SSA field manager; owned-object watches; periodic resync; events `DriftCorrected`.
**Acceptance:** envtest: delete Service → recreated; edit Service selector → restored; change pod label → restored. e2e: change `work_mem` → visible via `SHOW` within 30 s without restart; change `shared_buffers` → instance restarts once and `ConfigApplied=True`; HBA change applied by reload.

## Phase 5 — IM status API (mTLS) & cluster status
**Goal:** operator learns instance truth over the secure API.
**Scope:** per-cluster CA + IM server cert + operator client cert (minimal TLS just for IM API), `/v1/status`, `/v1/restart`, `/v1/checkpoint`, operation IDs; operator polling (5 s, jittered) feeding `status.instances[]`, conditions, phase; unreachable handling (`role: unknown`, `InstanceUnreachable`); IM volume stats + `DiskPressure`/`WALDiskPressure` conditions with `spec.monitoring.diskThresholds` (ADR-018); replace Phase-4 annotation handshake with `/v1/restart`; operator metrics basics.
**Acceptance:** unit tests for status mapping and disk-threshold hysteresis; envtest with fake IM (incl. unreachable → `unknown`, no failover); e2e: status shows LSN/timeline/version and volumes; filling the data volume with `fallocate` sets `DiskPressure` Warning then Critical on kind **and** k3d local-path, and freeing it clears the condition; IM API rejects a client cert from a different cluster's CA; restart via API works.

## Phase 6 — Streaming replicas & scaling
**Goal:** `instances: 3` with streaming replication.
**Scope:** `streaming_replica` role (password temporarily, cert auth in Phase 14 — TODO(P14)), slot reconcile (`/v1/slots/reconcile`), clone via pg_basebackup, `-ro`/`-r` services, role labels, lag reporting, scale up/down with serials never reused, `NeedsReclone` detection.
**Acceptance:** e2e `p6-replicas`: 3 instances Ready; write on primary visible on replicas via `-ro`; scale 3→5→2 (removes highest serials, slots dropped); kill a replica's PVC data → `NeedsReclone` → re-cloned automatically.

## Phase 7 — Probes hardening, PDBs, scheduling
**Scope:** final probe semantics (02 §6), configurable thresholds, PDBs, anti-affinity & topology spread, priority class, tolerations, `/dev/shm` sizing.
**Acceptance:** e2e: 3 instances land on 3 distinct nodes; `kubectl drain` of a replica node respects PDB; long recovery (simulated by large WAL replay) not killed by liveness.

## Phase 8 — Primary lease & fencing primitives
**Goal:** the safety mechanism, before any automation uses it.
**Scope:** voter abstraction in `internal/lease` (03 §3) with the voter set fixed to the Lease voter (`spec.ha.quorum.mode: KubernetesLease` only — instance voters are TODO(P10b)), IM holder loop with independent deadline timer (03 §3.3), acquirer rule (03 §3.4) used only at bootstrap, terms, self-fence on loss of sustain quorum, voluntary step-down when `targetPrimary≠me`, explicit release on shutdown, manual fence annotation (03 §4), CEL timing rule, metrics `lease_renew_age`. HA model tests (08 §3.2) introduced here.
**Acceptance:** model tests (rapid) green with ≥ 10k steps; test-im with fake lease store: renew failure → postmaster stopped within `renewDeadline+fenceTimeout`; e2e: Chaos Mesh partition primary↔API server → primary stops ≤ 13 s with defaults and clients get disconnected (ledger writer observes errors, not silent success); manual fence/unfence works.

## Phase 9 — Planned switchover
**Scope:** `PostgresSwitchover` CRD + controller + IM `/v1/demote`, `/v1/promote` (03 §7), shutdown-LSN handoff, single-active rule, TTL cleanup, operator probe measuring `writeUnavailableMillis`, `PostgresPrimaryOverride` CRD + `targetPrimary` precedence function (03 §8.1) — switchover completion creates/updates the override.
**Acceptance:** e2e `p9-switchover`: 10 consecutive switchovers (5 `Graceful`, 5 `Fast`) under ledger write load → 0 lost acked writes, 0 overlap, p95 write unavailability ≤ 5 s; switchover to a lagging target is Rejected; concurrent second switchover Rejected; old primary rejoins with no pg_rewind needed (asserted from IM logs); `kubectl delete pod` of the primary under ledger load → shutdown handoff, 0 lost acked writes, no rewind (ADR-021); fast stop forced to exceed its wait (blocked WAL sender) → `lossy: true`, old primary rejoins via rewind.

## Phase 10 — Automatic failover & rejoin
**Scope:** failure detection (03 §5.1), damping (§5.2), candidate selection (§5.3, async path), promotion workflow (§5.4) incl. creating/updating the PostgresPrimaryOverride and `FailoverUnacknowledged`, pg_rewind rejoin (§5.5) incl. the `pgkeeper_rewind` role and HBA (password auth until Phase 14 — TODO(P14)), stranded-instance handling (§11), crash handling on the primary (`spec.ha.crashHandling`, 03 §3.7, ADR-019), events/metrics.
**Acceptance:** unit/property tests for candidate selection; model tests extended with operator; e2e-chaos subset: kill primary pod, stop primary's kind node container, partition primary, kill operator during failover, SIGSTOP primary postmaster > lease duration (documented expected loss with async) → for each: new primary ≤ 30 s, overlap = 0 s, cluster Healthy after heal, old primary rejoins via rewind.

**Acceptance (crash handling):** e2e: kill the primary's postmaster once → restarted in place, same primary, no override, 0 lost acked writes; kill it `maxRestarts` times within `window` → `CrashLoop`, failover, override created; `policy: FailoverImmediately` → first kill fails over; single-instance cluster in crash loop keeps restarting and reports `CrashLoop`.

## Phase 10b — Quorum lease (peer voting)
**Goal:** a healthy primary survives an API-server outage, and runs on its own while the API server is up (ADR-016).
**Scope:** instance voters and `/v1/vote` (03 §3.2), `pgkeeper-instance` peer certs, sustain/acquire quorums, `Peers` mode, failure detection by acquire-quorum reports (03 §5.1), voter-set membership with joint quorums and `voterRemovalDelay` (03 §3.5), `QuorumUnavailable` + human-forced promotion, status `quorum` block, metrics (`pgkeeper_quorum_voters_granted`, `pgkeeper_quorum_term`). Model test for joint-quorum commit rules written **before** the implementation.
**Acceptance:** model tests (rapid) green with ≥ 10k steps including voter restarts and membership changes; test-im with in-process voters; e2e-chaos on kind **and** k3d in mode `Peers`: every row F1–F16 of ADR-016 meets its expected outcome, overlap = 0 s throughout; on k3d, restarting the single server causes no fence.

## Phase 11 — Synchronous replication
**Scope:** `replication.synchronous` (Off/Quorum, Preferred/Required), maintenance of `synchronous_standby_names` by primary IM, degraded handling, `SynchronousCommitOverridden` condition, candidate-selection quorum rule (§5.3 step 4).
**Acceptance:** e2e-chaos with `Required`: all fault scenarios incl. SIGSTOP freeze → **0 lost acked writes, 0 stolen ids**; `Preferred` with 2 replicas down keeps accepting writes and sets `SynchronousDegraded`.

## Phase 12 — Primary pinning
**Scope:** `spec.primary.pin` Preferred/Strict, human-gated switchback on override deletion (03 §8.1, ADR-017), `SwitchbackWaiting`, interaction rules with switchover, `PinTargetInvalid`, `StrictPinWaiting`; sample ValidatingAdmissionPolicy restricting `spec.primary` edits.
**Acceptance:** e2e: set Preferred pin → automatic switchover to pinned; kill pinned → failover elsewhere, override created → pinned recovers → **no** switchback while the override exists → delete override → Graceful switchover to pinned; switchover to a non-pinned instance under Preferred updates the override and is not pulled back; Strict pin + kill pinned → no promotion, condition set, pin removal → failover proceeds; VAP denies unauthorized user.

## Phase 13 — Primary-aware rolling updates
**Scope:** spec-hash per pod, replica-first rollout, Switchover/Restart strategies, Supervised mode, eviction-aware switchover, `--max-concurrent-cluster-rollouts`.
**Acceptance:** e2e: minor image bump (e.g. 18.x → 18.y digest) under ledger load → one switchover, write unavailability ≤ 5 s, 0 lost writes; Supervised waits for a PostgresSwitchover; single-instance uses Restart; `kubectl drain` primary node → switchover (triggered by the cordon, 03 §9) precedes eviction, no override created.

## Phase 14 — TLS
**Scope:** 05 §5 all modes; cert auth for `streaming_replica` (remove TODO(P14) password); HBA final form (no non-TLS remote); rotation; per-role connection Secrets (opt-in field reserved for Phase 15); cert-manager integration tested if cert-manager installed by `make infra-up CERT_MANAGER=1`.
**Acceptance:** e2e: `sslmode=verify-full` with CA from Secret succeeds against all three services; non-TLS remote connection rejected; forced rotation (short validity in test) → no replication break, clients reconnect fine; UserProvided expiry warning.

## Phase 15 — PostgresRole
**Scope:** 05 §1 incl. SCRAM verifier, password rotation on Secret change, adopt annotation, deletion policies, drift resync, connection Secret.
**Acceptance:** envtest + e2e: create role → login works; rotate Secret (unlabelled, user-owned — ADR-022) → old password fails, new works within 60 s; 10 resyncs without changes apply nothing and raise no `DriftDetected`; manual `ALTER ROLE ... PASSWORD` → restored with `DriftDetected`; manual `ALTER ROLE ... CONNECTION LIMIT 1` → reverted on resync with `DriftDetected` event; password never appears in Postgres logs (grep artifacts) nor operator logs; Drop policy reassigns owned objects.

## Phase 16 — PostgresDatabase
**Acceptance:** create db with owner, extensions (contrib) and schemas; immutable change → UnsupportedChange; Drop with active connections refused unless force annotation.

## Phase 17 — PostgresGrant
**Acceptance:** property tests for diff; e2e: grants applied; manual extra GRANT by user is **not** revoked; manual REVOKE of a managed privilege is restored; removing a privilege from spec revokes only that; new table in AllInSchema scope gets SELECT within one resync; defaultPrivileges effective for new tables created by `forRole`.

## Phase 18 — Backup stores & continuous WAL archiving
**Scope:** `PostgresBackupStore` (S3 first, then SFTP, PVC, GCS/Azure behind emulator caveats), store verification probe, WAL-G env rendering, `wal-archive`/`wal-restore` subcommands via IM socket, parallel archive look-ahead, I6 ownership file, status & conditions, metrics.
**Acceptance:** e2e (SeaweedFS + SFTP): archiving runs, `pg_switch_wal()` segment appears in store within 10 s; failover → new timeline + history file archived; primary's egress to the store blocked, `pg_switch_wal()`, primary killed before it archives → the segment reaches the store via a replica (ADR-020) and PITR across that failover has no gap; same name with different content → `ArchiveConflict`, never overwritten; store creds wrong → `ContinuousArchiving=False`, WAL accumulates, fix creds → drains; second cluster pointed at same serverName → refused.

## Phase 19 — On-demand base backups
**Scope:** `PostgresBackup` Full/Delta, PreferStandby selection, delta parent resolution & fallback, completion only after stop-LSN archived, queueing.
**Acceptance:** e2e: Full from standby completes; Delta after writes is smaller than Full (assert ratio < 0.5 for small change set); backup during switchover either completes or fails cleanly (no half-success status).

## Phase 20 — Scheduled backups & retention
**Acceptance:** schedule with 1-minute cron in test → backups created, `fullEvery` honoured; retention removes old backups/WAL but keeps `minFullBackups` and window; retention skipped while archiving broken; `firstRecoverabilityPoint` updated.

## Phase 21 — Restore & PITR
**Scope:** `bootstrap.recovery` (04 §7), target types, serverName collision CEL, post-restore full backup, scale-out after restore, `RecoveryTargetUnreachable`; restore drill (04 §9) as stretch.
**Acceptance:** e2e for S3 and SFTP: timestamped-rows scenario restores exactly to T (inclusive/exclusive variants); restore through a delta chain of 3; restore across a failover timeline switch; unreachable target → Failed with condition.

## Phase 22 — Logging pipeline & access logs
**Scope:** categorisation (06 §3.2), access record normalisation, `spec.logging` mapping incl. PG18 `log_connections` list form, redaction lexer, pgaudit via PG18 image-volume extension (sample extension image built in repo), auth-failure/connection counters.
**Acceptance:** unit/property tests for categoriser and redaction; e2e: successful and failed logins produce `access` records with correct fields on stdout; pgaudit DDL record on PG18; redaction on → no literals in logs.

## Phase 23 — Metrics, alerts, Grafana, notifications
**Scope:** full IM metric set incl. volume and cgroup metrics (06 §2.1), alert table (06 §2.3) with `promtool test rules` cases, Grafana dashboards, notification webhook (06 §2.5, `spec.notifications`, `--notify-webhook-secret`).
**Acceptance:** `test-im` scrapes metrics on 16/17/18 (version-specific views); e2e with `INFRA_PROMETHEUS=1`: PrometheusRule loads (promtool check + rule tests), induced archive failure fires `ArchivingFailing` within rule window, induced backend OOM (memory-hungry query under a low limit) fires `PostgresBackendOOMKilled`; Grafana JSON validates; webhook e2e with an in-cluster echo receiver: one failover produces exactly one `FailoverStarted` and one `FailoverCompleted` delivery, receiver down for 2 min → delivered after recovery, webhook URL absent from all logs.

## Phase 24 — Dashboard v1
**Scope:** 06 §4–§5 v1: OIDC (Dex locally), impersonation, fleet/cluster views, SSE status, live logs via pod-log follow with filters, access log view, limits & drop accounting, security headers.
**Acceptance:** Go API tests with Dex: user A (viewer of ns a) sees only ns a clusters and logs; user B denied; the dashboard holds no IM client cert and never connects to port 8000 (ADR-010); SSE delivers status change within 5 s of a switchover; log stream shows new `access` line within 3 s of a login; Playwright smoke: login → cluster view → logs tab.

## Phase 25 — Dashboard v2 (actions)
**Acceptance:** switchover/backup/fence/acknowledge-failover via UI create or delete CRs with `requested-by`; viewer role gets 403 from K8s (not from dashboard logic); audit log line emitted; CSRF test.

## Phase 26 — Multi-namespace, operator HA, scale, NetworkPolicy
**Scope:** watch scopes `all|list|selector`, instance-id label filtering, label-restricted caches, leader election failover, `--max-concurrent-cluster-rollouts`, optional per-cluster NetworkPolicy, load test with fake IMs (200 clusters).
**Acceptance:** e2e: operator in `list` mode ignores clusters outside list; two operator installs with different instance-ids don't touch each other's clusters; kill leader → reconcile resumes ≤ 20 s and running primaries unaffected; load test p99 reconcile < 2 s, operator RSS < 512 MiB.

## Phase 27 — Connection pooler (optional)
**Scope:** `PostgresPooler` (PgBouncer image chosen & pinned at phase start; PgBouncer 1.26 released Sept 2026 with CVE fixes), auth via `auth_query` with a dedicated role, PAUSE/RESUME integration in switchover.
**Acceptance:** switchover under load through pooler → 0 client-visible errors (queries queue), p95 added latency during switchover ≤ 5 s.

## Phase 28 — Release hardening
**Scope:** upgrade tests (N-1 → N), restore drills scheduled, Helm chart, cosign signing + SBOM + provenance for all images, `kubectl-pgkeeper` plugin (status/psql/switchover/backup), docs site, full `e2e-chaos` nightly green 7 days in a row, PG19 support once GA (add to matrix), API review → plan `v1beta1`.
**Acceptance:** release checklist in `docs/release.md` fully ticked.
