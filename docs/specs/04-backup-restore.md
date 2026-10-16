# 04 — Backup, Retention, Restore and PITR

## 1. Model in one paragraph
Point-in-time recovery needs two things: a **base backup** (a consistent-enough copy of PGDATA taken at LSN X) and an **unbroken WAL archive** from X to the target time. Restore = fetch base backup + replay archived WAL until the target. "Incremental" in this spec means WAL-G **delta** backups: a base backup that stores only pages changed since a parent backup; restore fetches the chain automatically. Continuous WAL archiving is itself the finest-grained incremental backup — base backups just bound restore time.

## 2. Backup store layout
```
<store root>/<prefix>/<serverName>/
    basebackups_005/      # WAL-G base & delta backups (+ sentinel JSON)
    wal_005/              # archived WAL segments + timeline history files
    pgkeeper/
        cluster.json      # cluster UID, namespace, created, pg major, system identifier
        lock              # written by the archiving cluster; see I6
```
- `serverName` defaults to the cluster name; recovery clusters must use a different one when sharing a store (01 §9).
- **I6 enforcement:** on first archive, IM writes `pgkeeper/cluster.json` with the cluster UID and Postgres `system_identifier`. Every later archive attempt checks it; on mismatch it fails with `ArchivePathOwnedByAnotherCluster` (archive stops, WAL accumulates, condition `ContinuousArchiving=False`) — never overwrites.

## 3. Engine abstraction
```go
type BackupEngine interface {
    ArchiveWAL(ctx, walPath string) error
    RestoreWAL(ctx, walName, destPath string) error            // returns ErrNotFound distinctly
    BaseBackup(ctx, opts BackupOptions) (BackupResult, error)  // opts.Method: Full|Delta
    FetchBackup(ctx, backupID string, destPGDATA string) error // resolves delta chains
    ListBackups(ctx) ([]BackupInfo, error)
    ApplyRetention(ctx, policy RetentionPolicy) (RetentionResult, error)
    Verify(ctx) error                                          // store reachability probe
}
```
- v1 implementation: `walg` — execs the injected `/pgkeeper/bin/wal-g` with a generated env file (`/pgkeeper/run/walg.env`, mode 0600) and parses `--json` output.
- Sidecar engines (later, ADR-006): same interface proxied over gRPC on a unix socket shared via an emptyDir with a sidecar container (barman-cloud, pgBackRest, native PG17). Sidecars receive PGDATA read-only plus a scratch volume.

### 3.1 Store type → WAL-G mapping
| Store | WAL-G config |
|---|---|
| S3 / S3-compatible | `WALG_S3_PREFIX=s3://bucket/prefix/serverName`, `AWS_ENDPOINT`, `AWS_S3_FORCE_PATH_STYLE`, `AWS_REGION`, creds from Secret or IRSA (projected token) |
| GCS | `WALG_GS_PREFIX=gs://bucket/prefix/serverName`, `GOOGLE_APPLICATION_CREDENTIALS` file or GKE Workload Identity |
| Azure | `WALG_AZ_PREFIX=azure://container/prefix/serverName`, account key / SAS / workload identity |
| SFTP | `WALG_SSH_PREFIX=ssh://host/path/serverName`, `SSH_PORT`, `SSH_USERNAME`, `SSH_PRIVATE_KEY_PATH`; known_hosts enforced (verify WAL-G option name at phase start; if WAL-G cannot enforce host keys, SFTP support is blocked until patched) |
| PVC | `WALG_FILE_PREFIX=/backup/serverName`, RWX claim mounted at `/backup` |
Common: `WALG_COMPRESSION_METHOD`, `WALG_UPLOAD_CONCURRENCY`, `WALG_PGP_KEY_PATH` (client-side encryption), `WALG_DELTA_MAX_STEPS`, `PGHOST=/run/postgresql`.

Credentials are mounted as files from Secrets into `/pgkeeper/run/store/` (projected volume) — never as env vars on the container spec (they'd show up in `kubectl describe`).

## 4. Continuous WAL archiving
- `archive_mode = always` on every instance (ADR-020). Replicas archive the segments they receive, so WAL the old primary streamed but never archived still reaches the store, and a failover leaves no archive gap. On promotion the new primary archives its new timeline, the `.partial` segment and the `.history` file.
- **Dedup** (ADR-020): before uploading, `wal-archive` checks whether the segment already exists in the store. Same content (size + checksum) → success without upload; different content for the same name → failure `ArchiveConflict` (never overwrite; WAL-G `WALG_PREVENT_WAL_OVERWRITE=true`). The primary normally uploads first; replicas mostly hit the existence check (one HEAD request per segment per replica).
- Exception: the PITR-bootstrap instance uses `archive_mode = on` until its first restart after promotion (§7), so WAL fetched from the source store is never re-archived.
- `archive_command = '/pgkeeper/bin/pgkeeper-instance wal-archive %p'`; `archive_timeout = spec.backup.walArchiving.archiveTimeout` (default 60 s) bounds RPO-to-archive for idle systems.
- `wal-archive` → local IM over unix socket → engine. IM may upload up to N ready segments in parallel (look-ahead in `pg_wal/archive_status/*.ready`) to keep up with bursty write loads; returns success for already-uploaded segments (idempotent).
- Success/failure counters, last archived/failed WAL & time → `/v1/status` → cluster status + metrics.
- Condition `ContinuousArchiving=False` when last failure is newer than last success, or no success within `3 × archiveTimeout` while WAL is being generated.
- Disk-safety alarm: metric `pgkeeper_wal_ready_segments` — alert if growing (archive stuck fills `pg_wal`, which eventually stops the primary).

## 5. Base backups
- Triggered by `PostgresBackup` (or a schedule creating one).
- Operator picks instance: `PreferStandby` → most caught-up streaming replica, else primary; `Primary` → primary.
- IM runs `wal-g backup-push $PGDATA` (local mode — reads PGDATA directly, avoiding the remote BASE_BACKUP protocol issues affecting released WAL-G versions on PG15+) with:
  - Full: `--full`
  - Delta: `--delta-from-name <parent>` where parent = latest successful backup on the **current timeline** of this cluster; if none or chain length ≥ `fullEvery`, fall back to Full and record `fellBackToFull: true`.
- Backups from a standby are supported by WAL-G (non-exclusive backup API); the IM verifies that WAL archiving on the primary has advanced past the backup's stop LSN before marking `Completed` (otherwise the backup isn't restorable).
- One backup per cluster at a time; concurrent requests queue (`phase: Pending`, reason `BackupInProgress`).
- Result recorded in `PostgresBackup.status` (01 §7), plus metadata stored by WAL-G as user data (`--add-user-data '{"pgkeeperBackup":"<ns>/<name>","clusterUID":...}'`).

## 6. Schedules and retention
- `PostgresScheduledBackup` controller uses `robfig/cron/v3` semantics with `timeZone`; missed runs while operator was down: run once if within `startingDeadline` (default 1 h), else skip with event.
- Every `fullEvery`-th run is Full; others Delta.
- **Retention** (`cluster.spec.backup.retention`) applied by operator daily and after each successful backup via IM `/v1/retention/apply`:
  - keep every backup needed to restore any point within `recoveryWindow`, **and** at least `minFullBackups` full backups (with their delta chains);
  - WAL-G: `delete retain FULL <n> --after <now-recoveryWindow> --confirm` then `delete garbage` for orphaned WAL (exact flags verified at phase start);
  - result → `status.firstRecoverabilityPoint`.
- Retention never runs while `ContinuousArchiving=False` (would risk deleting the only restorable base).

## 7. Restore and PITR (bootstrap of a new cluster)
1. Operator creates instance 1 only, with `bootstrap.recovery`.
2. IM resolves backup: given `backupID`, or latest backup whose stop time < target time (`wal-g backup-list --json --detail`).
3. `wal-g backup-fetch $PGDATA <backupID>` (delta chains handled by WAL-G).
4. IM writes recovery config: `restore_command = '/pgkeeper/bin/pgkeeper-instance wal-restore %f %p'` (reads from **source** store/serverName); `archive_command` targets the **new** cluster's own store/serverName from the start, with `archive_mode = on` so nothing is archived during recovery; before starting Postgres the IM writes `pgkeeper/cluster.json` (cluster UID + `system_identifier` from the restored `pg_control`) to the new path, so the I6 ownership check passes for the very first upload; `recovery_target_time|lsn|xid|name|immediate`, `recovery_target_inclusive`, `recovery_target_timeline`, `recovery_target_action = promote`; creates `recovery.signal`.
5. Starts Postgres; startup probe tolerates long replay (02 §6). Progress (replayed LSN vs target) reported in status (`phase: Restoring`).
6. On promotion: new timeline; the archiver uploads the `.history` file and new-timeline segments straight to the new cluster's path (no config switch, so nothing can land in the source path — I6). IM runs `CHECKPOINT`, then the operator triggers an immediate Full backup (a new cluster isn't PITR-able until its first base backup). `archive_mode` becomes `always` at the instance's next restart.
7. Operator scales up to `spec.instances` (replicas clone from the new primary).
- Recovery target not reachable (WAL gap / target beyond archive end) → `phase: Failed`, condition `RecoveryTargetUnreachable` with last replayed LSN/time; PGDATA kept for inspection.
- Restoring across major versions: rejected.

## 8. Native PG17+ incremental backup (designed, not in v1)
PG17 added `summarize_wal`, `pg_basebackup --incremental=<prior manifest>` and `pg_combinebackup`. A future `native` sidecar engine would: keep `summarize_wal=on` (cheap), store manifests per backup, and on restore run `pg_combinebackup` before WAL replay. Reasons not v1: requires own storage driver layer for 5 backends, own catalog/retention, and is PG17+ only, while WAL-G delta works on 16–18 today. Keep `summarize_wal` in the managed set so it can be turned on later without user conflicts.

## 9. Backup verification ("restore drill", Phase 21 stretch / Phase 28)
`PostgresCluster` annotation-driven or scheduled drill: create a throwaway recovery cluster (1 instance, `deletionPolicy: Delete`) from the latest backup to `immediate`, run `SELECT 1` + optional user SQL check from a ConfigMap, record result on the source cluster status (`lastRestoreDrill`), delete. An untested backup is a hope, not a backup.

## 10. Test matrix (local)
| Store | Local stand-in | Notes |
|---|---|---|
| S3 | SeaweedFS (`weed server -s3`) | MinIO community images no longer published (ADR-012). Garage as backup option. |
| GCS | fake-gcs-server | WAL-G needs custom endpoint support — verify `GOOGLE_STORAGE_ENDPOINT`/`STORAGE_EMULATOR_HOST` handling at phase start; if unsupported, GCS e2e runs only in a cloud CI job. |
| Azure | Azurite | same caveat as GCS |
| SFTP | atmoz/sftp (or linuxserver openssh-server) | with generated host key + known_hosts |
| PVC | local-path RWX? | local-path is RWO; use a single-node test or an NFS provisioner in k3d |

Mandatory e2e for each phase touching backup: write rows with timestamps → take backup → write more → record T → write more → restore to T into new cluster → assert exact row set. Plus: delta chain of 3 restores correctly; archive collision is refused; retention keeps window.
