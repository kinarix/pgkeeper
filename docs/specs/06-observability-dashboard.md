# 06 — Observability and Dashboard

## 1. Scope (C6)
- Metrics: Prometheus format from IMs and operator; Grafana dashboards + PrometheusRule alerts shipped as optional manifests.
- Logs: structured JSON on stdout (collected by whatever the platform runs — Loki, OpenSearch, Cloud Logging).
- Dashboard: an operational console with **live** state and **live-tail** logs. It stores nothing; history lives in Prometheus/log backend.

## 2. Metrics
### 2.1 Instance manager (`:9187/metrics`), labels `cluster, namespace, instance, role`
| Metric | Type | Source |
|---|---|---|
| `pgkeeper_up` | gauge | can connect |
| `pgkeeper_role` | gauge (1 primary/0 replica) | IM state |
| `pgkeeper_fenced` | gauge | IM state |
| `pgkeeper_lease_holder` | gauge | IM view of lease |
| `pgkeeper_lease_renew_age_seconds` | gauge | IM |
| `pgkeeper_quorum_term`, `pgkeeper_quorum_voters_granted{path}` (`lease` or `instances`) | gauge | IM view of the quorum lease (03 §3) |
| `pgkeeper_replication_lag_bytes` | gauge | primary: `pg_stat_replication` per `application_name` |
| `pgkeeper_replication_replay_lag_seconds` | gauge | `replay_lag` |
| `pgkeeper_replication_streaming` | gauge | replica WAL receiver |
| `pgkeeper_wal_ready_segments` | gauge | count `archive_status/*.ready` |
| `pgkeeper_archive_success_total` / `_failed_total`, `pgkeeper_archive_last_success_timestamp` | counter/gauge | `pg_stat_archiver` + IM |
| `pgkeeper_backup_last_success_timestamp`, `pgkeeper_backup_duration_seconds`, `pgkeeper_backup_size_bytes` | gauge | IM |
| `pgkeeper_connections{state}` , `pgkeeper_connections_max` | gauge | `pg_stat_activity` |
| `pgkeeper_xact_commit_total`, `_rollback_total`, `pgkeeper_deadlocks_total` per db | counter | `pg_stat_database` |
| `pgkeeper_database_size_bytes` per db | gauge | `pg_database_size` (every 5 min, cached) |
| `pgkeeper_checkpoints_*` | counter | `pg_stat_checkpointer` (PG17+) / `pg_stat_bgwriter` (16) |
| `pgkeeper_slot_retained_bytes{slot}` , `pgkeeper_slot_active{slot}` | gauge | `pg_replication_slots` |
| `pgkeeper_txid_age` (wraparound) | gauge | `age(datfrozenxid)` |
| `pgkeeper_locks_waiting` | gauge | `pg_locks` |
| `pgkeeper_pending_restart` | gauge | `pg_settings` |
| `pgkeeper_auth_failures_total{user}` | counter | from log stream (§3) |
| `pgkeeper_connections_total{user,db}` | counter | from log stream (cardinality-capped: top 50 users, rest `other`) |
| `pgkeeper_cert_expiry_timestamp` | gauge | IM |
| `pgkeeper_volume_bytes{volume,kind}` (`volume`: data, wal; `kind`: total, available) | gauge | IM `statfs`, every 15 s — works on local-path/hostPath where kubelet volume stats don't |
| `pgkeeper_volume_inodes{volume,kind}` (`kind`: total, free) | gauge | IM `statfs` |
| `pgkeeper_pg_wal_bytes` | gauge | size of `pg_wal` |
| `pgkeeper_cgroup_memory_bytes`, `pgkeeper_cgroup_memory_limit_bytes` | gauge | cgroup v2 `memory.current` / `memory.max` |
| `pgkeeper_cgroup_oom_kills_total` | counter | cgroup v2 `memory.events` `oom_kill` — catches backend OOM kills that don't restart the container |
| custom queries | any | ConfigMap (YAML: name, query, metrics[], cache TTL); per-query timeout 2 s |
Version-specific views (e.g. `pg_stat_checkpointer` vs `pg_stat_bgwriter`) are selected by detected major.

### 2.2 Operator (`:8080/metrics`)
controller-runtime defaults plus `pgkeeper_notifications_total{result}`, `pgkeeper_failovers_total{cluster,reason}`, `pgkeeper_switchovers_total{result}`, `pgkeeper_failover_duration_seconds` (detection → promoted), `pgkeeper_write_unavailable_seconds` (operator probe), `pgkeeper_drift_corrections_total{kind}`, `pgkeeper_clusters{phase}`, `pgkeeper_reconcile_errors_total{controller}`.

### 2.3 Alerts (PrometheusRule)
Shipped as an optional PrometheusRule; every rule has a `promtool test rules` case.

| Alert | Condition (sketch) | Severity |
|---|---|---|
| PrimaryMissing | no instance with `pgkeeper_role == 1` for 1 min | critical |
| FailoverHappened | `increase(pgkeeper_failovers_total[10m]) > 0` | info |
| FailoverUnacknowledged | PostgresPrimaryOverride older than 24 h | info |
| FencedInstance | `pgkeeper_fenced == 1` | warning |
| ReplicationLagHigh | lag > `maxFailoverLag` for 5 min | warning |
| ReplicaNotStreaming | `pgkeeper_replication_streaming == 0` for 2 min | warning |
| ArchivingFailing | last archive failure newer than last success | critical |
| WALReadySegmentsGrowing | `pgkeeper_wal_ready_segments` rising for 15 min | warning |
| BackupTooOld | last backup > 1.5 × schedule | warning |
| PostgresDiskPressure / PostgresWALDiskPressure | `pgkeeper_volume_bytes` available below `diskThresholds` | warning / critical |
| PostgresDiskWillFillIn4h | `predict_linear(pgkeeper_volume_bytes{kind="available"}[6h], 4*3600) < 0` | warning |
| PostgresInodesLow | inodes free < 10 % | warning |
| PostgresMemoryNearLimit | `pgkeeper_cgroup_memory_bytes / pgkeeper_cgroup_memory_limit_bytes > 0.9` for 10 min | warning |
| PostgresBackendOOMKilled | `increase(pgkeeper_cgroup_oom_kills_total[15m]) > 0` | critical |
| PostgresContainerRestarting | kube-state-metrics `increase(kube_pod_container_status_restarts_total[15m]) > 2` | warning |
| PostgresCPUThrottlingHigh | cAdvisor `container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total > 0.25` for 15 min | warning |
| PostgresConnectionsNearMax | `pgkeeper_connections / pgkeeper_connections_max > 0.8` for 5 min | warning |
| TxidWraparoundRisk | age > 1.5 B | critical |
| CertificateExpiringSoon | < 14 d | warning |
| SlotRetainingTooMuch | `pgkeeper_slot_retained_bytes` > 80 % of `maxSlotWALKeepSize` | warning |
| PendingRestart | > 24 h | info |

Disk alerts use IM-measured volume metrics, not kubelet volume stats (missing on local-path/hostPath volumes — ADR-018). CPU throttling and restarts need cAdvisor and kube-state-metrics, both standard in kube-prometheus.

### 2.4 Grafana
Dashboards JSON (provisioned via ConfigMap with `grafana_dashboard: "1"` label): Fleet overview, Cluster detail, Replication, Backups. Built in Phase 23.

### 2.5 Notifications (optional webhook, ADR-018)
- Without Prometheus/Alertmanager, people still get paged for HA incidents: the operator POSTs to a webhook.
- Config: per cluster `spec.notifications` (`webhookSecretRef`, `format: Generic|Slack`, `minSeverity`); operator-wide fallback `--notify-webhook-secret=<ns>/<name>` for clusters without their own. Off by default. The URL is a secret: read from the Secret, never logged, never in status or events.
- Events (fixed set):

| Event | Severity |
|---|---|
| FailoverStarted, FailoverCompleted | Critical |
| FenceApplied (involuntary only) | Critical |
| QuorumUnavailable, NoEligibleCandidate, StrictPinWaiting | Critical |
| ContinuousArchiving=False | Critical |
| DiskPressureCritical | Critical |
| FailoverDamped, SwitchoverFailed, BackupFailed | Warning |
| DiskPressureWarning (data or WAL) | Warning |
| InstanceUnreachable, BackendOOMKilled | Warning |
| FailoverUnacknowledged (> 24 h) | Info |

- Payload (`Generic`): `{cluster, namespace, clusterUID, event, severity, message, time, dashboardURL}`. `Slack`: same content as a `text` message. Never credentials, SQL text or client addresses.
- Delivery: async queue (never blocks reconcile); at-least-once; exponential backoff for up to 1 h, then drop with event `NotificationDropped`; dedupe key `<clusterUID>/<event>/<transitionTime>`; metric `pgkeeper_notifications_total{result}`.

## 3. Logs and access logs
### 3.1 Postgres logging settings (from `spec.logging`)
| Spec | Postgres |
|---|---|
| `connections: true` | `log_connections` — PG18 changed this to accept a list of aspects (`receipt, authentication, authorization, setup_durations`); IM maps `true` → `authorization` (PG18+) / `on` (16/17). **[High Confidence]** — verify exact PG18 values at phase start. |
| `disconnections: true` | `log_disconnections = on` (logs session duration) |
| `statement` | `log_statement` |
| `minDurationStatement` | `log_min_duration_statement` |
| `audit.enabled` | adds `pgaudit` to `shared_preload_libraries` (PG18 + extension image), `pgaudit.log = 'ddl, role'` default |
| always | `log_line_prefix` irrelevant (jsonlog), `log_checkpoints = on`, `log_lock_waits = on`, `log_autovacuum_min_duration = 10s`, `log_replication_commands = on` |

### 3.2 Categorisation (IM, deterministic rules on jsonlog fields)
| Category | Rule |
|---|---|
| `access` | message starts `connection received`, `connection authenticated`, `connection authorized`, `disconnection:`; or `error_severity=FATAL` with SQLSTATE `28P01`/`28000` (auth failure → `access` with `outcome=failure`) |
| `audit` | message starts `AUDIT:` (pgaudit) or IM-emitted SQL-reconcile events |
| `slow_query` | message starts `duration:` |
| `error` | severity ERROR/FATAL/PANIC not matched above |
| `system` | everything else |
Each access record is normalised to `{time, user, database, client_addr, client_port, application_name, backend_pid, event: connect|authenticate|authorize|disconnect|auth_failed, session_duration_ms}` alongside the raw record.

### 3.3 Redaction
`spec.logging.redactStatements: true` → IM replaces string/numeric literals in `statement` and `message` fields with `$n` placeholders (use a SQL lexer — `pg_query_go` normalize, which needs cgo → instead implement a small literal-stripping lexer in pure Go; property-tested). Default off. Rationale: statement text frequently contains personal data (DPDP/GDPR).

## 4. Dashboard architecture
```
Browser ──OIDC (Auth Code + PKCE)──► IdP
   │  session cookie (HttpOnly, SameSite=Strict, 8 h)
   ▼
pgkeeper-dashboard (Go, net/http, embedded SPA)
   ├─ K8s API with Impersonate-User/Group = OIDC subject/groups   (ADR-010)
   │     list/watch CRs, read Lease, create PostgresSwitchover/PostgresBackup
   │     GET pods/{name}/log?follow=true   (live tail, ADR-011)
   └─ Prometheus HTTP API (optional, PROMETHEUS_URL) for sparkline charts
Browser ◄── Server-Sent Events (status deltas, log lines)
```
- Backend: Go, single binary; frontend: TypeScript + React + Vite, built into `internal/dashboard/web/dist` and embedded with `go:embed`. (Alternative accepted if the team prefers less JS: server-rendered templates + htmx + SSE — decide in Phase 24 ADR.)
- No database. Session store: signed+encrypted cookie (`securecookie`), server-side revocation not needed for v1.
- OIDC config: issuer URL, client ID/secret (Secret), groups claim name, allowed groups; any OIDC-compliant IdP (Dex for local tests; corporate IdP in prod).
- Local dev mode: `--auth=dev` with a fixed user mapped to a K8s ServiceAccount — only allowed when bound to `127.0.0.1` (refuses to start otherwise).

## 5. Dashboard features
### v1 (Phase 24, read-only)
- **Fleet view:** clusters across namespaces the user can list (watch via impersonated informers is not possible — use per-request list + server-side short cache keyed by user, 5 s TTL; or SSE polling every 5 s).
- **Per-instance detail comes only from CR status** (refreshed by the operator every 5 s); the dashboard never calls instance managers, so every byte it shows passed the user's RBAC (ADR-010).
- **Cluster view:** topology (primary, replicas, lag bars, sync state, lease holder + renew age, timeline), per-instance volume usage (data/WAL, with pressure highlighting) and memory vs limit, conditions, recent events, config hash/pending restart, last failover, archiving status, backups list & recoverability window, certificates expiry.
- **Live logs:** per instance or merged; filter by category (`access` default), user, database, severity, free-text (client-side over the live window); pause/resume; max 5,000 lines buffered in browser; server enforces max 10 concurrent streams per user and drops lines when the client is slow (shows "N lines dropped").
- **Access log view:** tabular live feed of normalised access records + counters (connections/min, auth failures/min by user) computed over the live window.
### v2 (Phase 25, actions)
- Trigger switchover (choose target, Graceful/Fast), trigger backup (Full/Delta), fence/unfence instance, **acknowledge failover** (delete the PostgresPrimaryOverride; the dialog states whether a switchback will follow), pause/resume reconcile — each creates/patches CRs **as the user** (so RBAC applies) and sets `pgkeeper.in/requested-by`.
- Confirmation dialogs showing the impact text from 03 §12.

### Non-features
Running SQL, viewing table data, editing configs, log history/search, user management. These belong to dedicated tools.

## 6. Security
- CSP: `default-src 'self'`; no inline scripts; SSE same-origin.
- CSRF: SameSite=Strict + double-submit token on POST.
- Log lines are rendered as text, never HTML.
- Dashboard audit log: every action → JSON log line `{actor, groups, action, target, result}` and a K8s Event on the target CR.
