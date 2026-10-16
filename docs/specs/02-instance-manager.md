# 02 — Instance Manager (`pgkeeper-instance`)

The instance manager (IM) is a static Go binary that runs as **PID 1** in the Postgres container of every instance pod. It is the only thing that starts, stops, promotes or demotes Postgres.

## 1. Why PID 1
- It must supervise the postmaster: forward signals, reap zombies, decide stop modes (smart/fast/immediate), restart on crash.
- **Container death semantics [High Confidence]:** when PID 1 of a PID namespace exits, the kernel SIGKILLs every other process in that namespace. If the IM crashes, Postgres dies with it — there is never an unsupervised postmaster that could keep accepting writes without a lease holder watching it.
- The pod never sets `shareProcessNamespace: true`: with it, PID 1 would be the pause container and Postgres would survive an IM crash. The operator always renders it as false.
- The official image's `docker-entrypoint.sh` is **not** used (it does its own initdb from env vars). Pod spec sets `command: ["/pgkeeper/bin/pgkeeper-instance", "run"]`.

## 2. Delivery into the official image
```
volumes:
  - name: pgkeeper-tools
    image:                                   # K8s ≥1.35 (beta, default on), GA in 1.36
      reference: ghcr.io/kinarix/pgkeeper-tools:<version>@sha256:...
      pullPolicy: IfNotPresent
  - name: pgkeeper-run      {emptyDir: {}}                 # writable runtime dir
  - name: tmp               {emptyDir: {}}
  - name: run-postgresql    {emptyDir: {}}                 # unix socket dir
  - name: shm               {emptyDir: {medium: Memory, sizeLimit: <sharedMemorySize>}}
  - name: pgdata            {persistentVolumeClaim: {claimName: <pod>}}
  - name: pgwal             {persistentVolumeClaim: {claimName: <pod>-wal}}   # optional
```
- Image-volume support is a **node** capability (kubelet feature gate + container runtime), not an API-server one, so a dry-run create proves nothing. The operator decides per pod: `image-volume` only if every node the pod may be scheduled on reports kubelet ≥ 1.35 and a runtime version known to support image volumes (`node.status.nodeInfo.kubeletVersion`, `containerRuntimeVersion`; minimum runtime versions, e.g. containerd 2.1 / CRI-O 1.31, **verified and pinned at Phase 0**), otherwise `init-copy`. Re-evaluated on node changes; existing pods are not restarted for it. Override with `--tools-delivery=image-volume|init-copy|auto` (default auto). If an image-volume pod fails with a volume mount error anyway, the operator recreates it with `init-copy` and records event `ToolsDeliveryFallback`.
- `init-copy` fallback: init container from the same tools image runs `/pgkeeper-instance install --to /pgkeeper/bin`, which copies itself and `/wal-g` into an emptyDir and verifies their checksums. (The tools image is `FROM scratch`: there is no shell and no `cp`.)
- Tools image: `FROM scratch`, contains `/pgkeeper-instance`, `/wal-g`, `/LICENSES/`. Both binaries `CGO_ENABLED=0`, `-trimpath`, static. WAL-G built from a pinned commit with build tags that avoid cgo (no brotli/libsodium/lzo); compression limited to lz4/zstd/lzma (ADR-006). Image is signed and gets an SBOM (Phase 28).
- Mounted at `/pgkeeper/bin` (read-only). IM writes nothing there.

## 3. Filesystem layout (all PG versions)
| Path | Purpose |
|---|---|
| `/var/lib/postgresql` | PGDATA PVC mount (matches the PG18+ official image volume) |
| `/var/lib/postgresql/<major>/data` | `PGDATA` (versioned so future `pg_upgrade --link` can create `<major+1>/data` on the same PVC) |
| `/var/lib/postgresql/wal` | WAL PVC mount when `walStorage` set; `initdb --waldir=/var/lib/postgresql/wal/<major>` |
| `/pgkeeper/run` | IM runtime: rendered config fragments, log FIFO, lock files, wal-g env |
| `/pgkeeper/run/certs` | TLS material projected from Secrets |
| `/run/postgresql` | Unix socket |
| `/dev/shm` | shared memory |

Container `securityContext`: `runAsUser: <postgresUID>`, `runAsGroup: <postgresGID>`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`. Pod `fsGroup: <postgresGID>`, `fsGroupChangePolicy: OnRootMismatch`.

## 4. Configuration

### 4.1 Sources
- IM watches **its own** `PostgresCluster` (read-only, via its ServiceAccount; RBAC restricted by `resourceNames`) and the `<cluster>-config` ConfigMap. The ConfigMap holds the operator-rendered desired config and a `configHash`, plus HA facts the IM needs: the voter set and `voterEpoch` (03 §3.5) and `failoverPossible` (03 §3.7).
- Pod-specific facts arrive as env: `PGK_CLUSTER`, `PGK_INSTANCE`, `PGK_NAMESPACE`, `PGK_POD_IP`.

### 4.2 Managed parameter set (users may not set these)
`listen_addresses, port, unix_socket_directories, data_directory, hba_file, ident_file, archive_mode, archive_command, archive_library, restore_command, archive_cleanup_command, primary_conninfo, primary_slot_name, recovery_target*, promote_trigger_file, synchronous_standby_names, synchronous_commit` (operator sets default; user may override per role/db via SQL), `ssl, ssl_cert_file, ssl_key_file, ssl_ca_file, ssl_crl_file, logging_collector, log_destination, log_directory, log_filename, log_rotation_*, log_line_prefix, wal_level` (min `replica`; `logical` allowed via `pgkeeper.in/wal-level` toggle in spec later), `hot_standby, wal_log_hints, summarize_wal, max_wal_senders, max_replication_slots, wal_keep_size, max_slot_wal_keep_size, allow_alter_system` (PG17+), `shared_preload_libraries` (merged from spec list), `extension_control_path, dynamic_library_path, cluster_name`.

### 4.3 Rendered files
- `postgresql.conf`: `include_dir = '/pgkeeper/run/conf.d'` plus nothing else; IM writes `00-defaults.conf`, `10-managed.conf`, `20-user.conf`, `30-instance.conf` (role-specific: replica `primary_conninfo`, slot).
- `pg_hba.conf` (05 §4) and `pg_ident.conf` written by IM.
- `postgresql.auto.conf`: on PG17+ `allow_alter_system = off`, so `ALTER SYSTEM` errors. On PG16 the IM empties `postgresql.auto.conf` before each start/reload and raises `DriftDetected` on the instance if it found content.

### 4.4 Apply loop
1. Desired hash changes → IM renders files atomically (write temp + rename).
2. `pg_ctl reload` / `SELECT pg_reload_conf()`.
3. Query `SELECT name FROM pg_settings WHERE pending_restart` → report in status API (`pendingRestart: [..]`).
4. IM **never restarts on its own** for config; the operator orchestrates restarts (03 §9) so the primary goes last.

## 5. Lifecycle state machine
```
           ┌──────────┐ empty PGDATA, bootstrap=initdb, I am targetPrimary
  start ──►│ Bootstrap├──────────────► initdb ─────────────┐
           └────┬─────┘ empty, bootstrap=recovery          │
                │      ─────────────► wal-g backup-fetch ──┤
                │ empty, someone else is primary           │
                │      ─────────────► pg_basebackup clone ─┤
                ▼ PGDATA exists                            ▼
           ┌──────────┐                              ┌───────────┐
           │ Decide   │──── lease held by me ───────►│ Primary   │◄── promote ──┐
           │ role     │──── else ───────────────────►│ Replica   │──────────────┘
           └──────────┘  (timeline diverged → pg_rewind first)  └─────┬─────┘
                                                      lease lost /    │
                                                      targetPrimary≠me│
                                                                      ▼
                                                               ┌────────────┐
                                                               │ Fenced     │ postgres stopped (immediate)
                                                               └────────────┘ until safe to rejoin as replica
```
Commands (subcommands of the same binary):
- `run` — the PID-1 supervisor (normal mode).
- `bootstrap initdb|clone|restore` — invoked internally by `run`; exposed for testing.
- `wal-archive <path>` / `wal-restore <file> <dest>` — called by Postgres as `archive_command` / `restore_command`; they talk to the local IM over a unix socket so concurrency, metrics and engine selection live in one place.
- `status` — prints local status JSON (debugging via `kubectl exec`).

### 5.1 Bootstrap: initdb (primary only)
`initdb --pgdata=$PGDATA --auth-local=peer --auth-host=scram-sha-256 --encoding=… --locale=… [--data-checksums] [--waldir=…]`. PG18's initdb enables data checksums by default **[High Confidence]**; we pass the flag explicitly for 16/17. Then start with a temporary local-only config, create owner role + database, `streaming_replica` role (cert auth only), `pgkeeper_monitor` (pg_monitor member), stop, mark bootstrap complete (`$PGDATA/.pgkeeper-bootstrapped` with cluster UID — protects against attaching a foreign PVC).

### 5.2 Bootstrap: clone (replica)
`pg_basebackup -h <cluster>-rw -U streaming_replica (cert) -D $PGDATA -X stream -c fast --slot=<slot>` (no `-R`: the IM writes recovery config itself), then IM writes `standby.signal` and `30-instance.conf`. Slot created beforehand by the primary IM on operator request (03 §2).

### 5.3 Bootstrap: restore
04 §7.

### 5.4 Signals and shutdown
| Trigger | Action |
|---|---|
| SIGTERM (pod delete, eviction) | Primary, no switchover in progress: **shutdown handoff** (03 §7.1, ADR-021) — `pg_ctl stop -m fast` (not smart — smart waits for clients, see 00 C4), wait ≤ `terminationGracePeriodSeconds - 5s`, then immediate; read the shutdown checkpoint LSN; release the lease with `release-reason=Shutdown` and `pgkeeper.in/shutdown-lsn` (omitted if the immediate fallback was needed). The operator promotes a replica that has received up to that LSN — no lost commits. Replica: fast stop. |
| Fence (no sustain quorum — 03 §3.3 / targetPrimary≠me while primary) | `pg_ctl stop -m immediate`; if postmaster still alive after `fenceTimeout`, SIGKILL the process group. |
| Postmaster crash (incl. in-place reinit after a backend crash, e.g. backend OOM kill) | Per `spec.ha.crashHandling` (03 §3.7, ADR-019). Default `RestartInPlace`: restart with backoff (`initial` 1 s → `max` 30 s) while still holding the lease; after `maxRestarts` (5) crashes in `window` (5 min), or if a restart doesn't accept connections within `startTimeout` (2 min): stop, report `CrashLoop`, release lease (`release-reason=CrashLoop` / `RecoveryTimeout`) → failover. If no failover is possible (single instance, Strict pin on self, no eligible candidate): keep restarting at `backoff.max` and keep the lease. `FailoverImmediately`: release the lease on the first crash (`release-reason=Crash`). Replicas always restart in place. Intentional stops never count as crashes. |
| SIGINT/SIGQUIT | Treated as SIGTERM. |

`terminationGracePeriodSeconds` default 60.

## 6. Probes (served on plain HTTP port 8001)
| Probe | Endpoint | Passes when | Defaults |
|---|---|---|---|
| startup | `/startupz` | Postgres accepts connections on the socket **and** (primary) not in recovery **or** (replica) in recovery and WAL receiver started or restore_command catching up | period 10s, failureThreshold 360 (1 h — large restores/replays must not be killed) |
| liveness | `/healthz` | IM main loop heartbeat < 10 s old and postmaster PID alive (or intentionally stopped: fenced/bootstrapping). Never fails because of lag or lease loss — the IM handles those itself; a kubelet restart would only add noise. | period 10s, failureThreshold 3 |
| readiness | `/readyz` | Accepting connections. Replica: additionally `lagBytes ≤ spec.ha.maxFailoverLag` if `readinessLagCheck: true` (default false). Primary: holds a valid lease. Fenced: never ready. | period 5s, failureThreshold 3 |

## 7. Status/Control API (HTTPS port 8000, mTLS)
- **Pull only:** the operator polls `GET /v1/status` every 5 s (jittered); the IM never pushes heartbeats. After 3 failed polls the operator marks the instance `role: unknown` (event `InstanceUnreachable`) — this never triggers failover by itself; failover liveness comes from the quorum lease (03 §5.1, ADR-018).
- Server cert from `<cluster>-im-tls`; clients must present a cert signed by the cluster CA with CN `pgkeeper-operator` or `pgkeeper-instance` (peer IMs: `/v1/vote` only). The dashboard never calls the IM; it reads CR status as the impersonated user (ADR-010).
- All mutating calls are **idempotent** and carry an `operationID`; IM keeps the last 100 operation results.

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/status` | role, timeline, LSNs, lag, lease view, config hash, pendingRestart, postgres version, WAL receiver state, archiver stats, volumes (statfs of data/WAL mounts: bytes, inodes; `pg_wal` size), cgroup memory (current, limit, oom_kill count), last errors |
| POST | `/v1/checkpoint` | CHECKPOINT (before switchover) |
| POST | `/v1/restart` | rolling-restart step (refused on primary unless `allowPrimary=true`) |
| POST | `/v1/promote` | only valid when IM holds an acquire quorum; see 03 §3.4 |
| POST | `/v1/vote` | peer-only: grant/renew/release a quorum-lease vote (03 §3.2); answered only after the vote is fsynced. Not exposed to operator or dashboard. |
| POST | `/v1/demote` | graceful hand-off step of switchover |
| POST | `/v1/slots/reconcile` | primary: ensure physical slots for given instance list, drop others (managed prefix only) |
| POST | `/v1/sql/roles/reconcile` | 05 §1 |
| POST | `/v1/sql/databases/reconcile` | 05 §2 |
| POST | `/v1/sql/grants/reconcile` | 05 §3 |
| POST | `/v1/backup` | start backup (async), returns operationID |
| GET | `/v1/operations/{id}` | poll async op |
| POST | `/v1/retention/apply` | run retention on the store |

Arbitrary SQL execution endpoints are **forbidden** by design.

## 8. Metrics (port 9187, `/metrics`)
See 06 §2 for the metric list. Collection runs over the local unix socket as `pgkeeper_monitor`, with per-query timeouts (2 s) and a global scrape budget (5 s). Volume (`statfs`, every 15 s) and cgroup v2 memory metrics (`memory.current`, `memory.max`, `memory.events`) are read from the filesystem, not SQL; on cgroup v1 hosts the memory metrics are absent and nothing fails.

## 9. Logging
- IM's own logs: JSON lines on stdout (`logr` + zap), `"logger":"instance-manager"`.
- Postgres logs: `logging_collector=on`, `log_destination=jsonlog` (PG15+), `log_directory=/pgkeeper/run/log`, `log_filename=postgres.json`. The IM creates `postgres.json` as a **named pipe (FIFO)** before start, reads it continuously, wraps each record as `{"logger":"postgres","category":"<access|audit|slow_query|error|system>","record":{...}}` and writes to stdout. If the reader stalls, the collector blocks; therefore the reader never does blocking I/O beyond stdout and has a watchdog — on FIFO failure the IM switches the collector to a rotating plain file and tails it (degraded mode, reported in status).
- Categorisation rules: 06 §3.

## 10. Testing requirements specific to the IM
- Integration tests run the IM **outside Kubernetes** with testcontainers-go against `postgres:16`, `:17`, `:18` (Debian) — the K8s API is faked with an in-process fake Lease store implementing the same interface.
- Must cover: initdb, clone, promote, demote, rewind after divergence, fence on lease loss (inject clock/lease failures), fence on loss of sustain quorum with several in-process voters, vote persistence across IM restart (no second grant within `leaseDuration`), FIFO log parsing, config reload + pending_restart detection, crash restart backoff, crash-loop and start-timeout escalation for both `crashHandling` policies, backend-crash reinit counted as a crash, PID-1 reaping, volume stats on a small loop/tmpfs mount filled to thresholds, cgroup file parsing (v2 present, v1/absent).
