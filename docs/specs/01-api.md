# 01 — API (CRDs)

API group `pgkeeper.io`, version `v1alpha1` until Phase 28. All kinds are **namespaced**. Validation is OpenAPI + CEL (`x-kubernetes-validations`); no admission webhook (ADR-008).

## 0. Conventions (apply to every kind)

- `spec` is desired state; `status` is written **only** by the operator via the status subresource.
- `status.observedGeneration` and `status.conditions[]` (standard `metav1.Condition`) on every kind. Condition types are listed per kind; reasons are CamelCase constants defined in `api/v1alpha1/conditions.go`.
- Every kind gets printer columns (`kubectl get` must be useful without `-o yaml`).
- Cross-object references are `LocalObjectReference` (same namespace only). Cross-namespace references are not allowed in v1 (tenancy boundary).
- Durations are strings parsed by `metav1.Duration` (`"15s"`, `"10m"`). Quantities use `resource.Quantity`.
- Fields marked **immutable** use CEL transition rules: `self == oldSelf`.
- Short names: `pgc`, `pgsw`, `pgpo`, `pgrole`, `pgdb`, `pggrant`, `pgbs`, `pgbackup`, `pgsb`, `pgpool`.
- Finalizer: `pgkeeper.io/finalizer` on kinds that own external state (Cluster, Role, Database, Grant, Backup).
- Annotations understood on any kind:
  - `pgkeeper.io/reconcile: paused` — controller records `Paused=True` and does nothing else.
  - `pgkeeper.io/requested-by` — set by the dashboard to the end-user identity for audit.

## 1. PostgresCluster

### 1.1 Example
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresCluster
metadata:
  name: orders
  namespace: team-a
spec:
  instances: 3
  image: docker.io/library/postgres:18.4-trixie@sha256:...   # digest required when spec.imagePolicy=RequireDigest
  imagePullPolicy: IfNotPresent
  imagePullSecrets: []
  postgresUID: 999
  postgresGID: 999

  storage:
    size: 50Gi
    storageClassName: standard
  walStorage:               # optional; separate PVC for pg_wal
    size: 10Gi

  resources:
    requests: {cpu: "1", memory: 2Gi}
    limits:   {memory: 2Gi}
  sharedMemorySize: 256Mi   # /dev/shm emptyDir (medium: Memory)

  postgresql:
    parameters:
      max_connections: "300"
      shared_buffers: "512MB"
    hba:
      - {type: hostssl, database: all, user: all, address: 10.0.0.0/8, method: scram-sha-256}
    extensions:             # PG18+ only (image volume + extension_control_path)
      - name: pgaudit
        image: ghcr.io/example/pgaudit-ext:18-17.1@sha256:...
    sharedPreloadLibraries: [pg_stat_statements]

  bootstrap:                # exactly one of initdb | recovery
    initdb:
      database: app
      owner: app
      ownerSecretRef: {name: orders-app}     # optional; generated if absent
      encoding: UTF8
      locale: C.UTF-8
      dataChecksums: true

  replication:
    synchronous:
      mode: Off             # Off | Quorum
      number: 1             # ANY <number> (...)
      dataDurability: Preferred   # Required | Preferred
    slots:
      enabled: true
      maxSlotWALKeepSize: 10Gi

  ha:
    failoverDelay: 0s
    maxFailoverLag: 64Mi
    lease:
      duration: 15s
      renewDeadline: 10s
      retryPeriod: 2s
    fenceTimeout: 3s
    crashHandling:          # postmaster crash on the primary (03 §3.7, ADR-019)
      policy: RestartInPlace   # RestartInPlace | FailoverImmediately
      maxRestarts: 5           # crashes within window before CrashLoop → release lease → failover
      window: 5m
      backoff: {initial: 1s, max: 30s}
      startTimeout: 2m         # restarted primary must accept connections within this, else failover
    quorum:
      mode: KubernetesLease   # KubernetesLease | Peers (03 §3, ADR-016); default switches to Peers in Phase 28
      voterRemovalDelay: 30s  # failed instances leave the voter set after this

  primary:
    pin:                    # optional
      instance: orders-2
      policy: Preferred     # Preferred | Strict
      acknowledgeStrictRisk: false
      # no switchbackDelay: switchback happens when a human deletes the PostgresPrimaryOverride (§12, ADR-017)
    updateStrategy: Switchover   # Switchover | Restart
    updateMode: Unsupervised     # Unsupervised | Supervised

  backup:
    storeRef: {name: s3-prod}
    walArchiving: {enabled: true, archiveTimeout: 60s}
    target: PreferStandby   # Primary | PreferStandby
    retention:
      recoveryWindow: 14d
      minFullBackups: 2

  tls:
    mode: OperatorManaged   # OperatorManaged | CertManager | UserProvided
    certManager: {issuerRef: {kind: ClusterIssuer, name: internal-ca}}
    userProvided: {serverSecretRef: {name: ...}, caSecretRef: {name: ...}}

  logging:
    level: info             # instance manager log level
    connections: true
    disconnections: true
    statement: ddl          # none | ddl | mod | all
    minDurationStatement: 500ms
    redactStatements: false
    audit: {enabled: false} # requires pgaudit extension (PG18+)

  monitoring:
    podMonitor: false       # create a PodMonitor (prometheus-operator CRD) if installed
    customQueriesConfigMapRef: {name: orders-queries}
    diskThresholds: {warningPercent: 85, criticalPercent: 95}   # DiskPressure / WALDiskPressure (ADR-018)

  notifications:            # optional HA webhook (06 §2.5, ADR-018)
    webhookSecretRef: {name: orders-alerts, key: url}   # URL is a secret; never logged
    format: Slack           # Generic | Slack
    minSeverity: Warning    # Info | Warning | Critical

  scheduling:
    antiAffinity: {type: Preferred, topologyKey: kubernetes.io/hostname}   # Preferred | Required | Disabled
    nodeSelector: {}
    tolerations: []
    topologySpreadConstraints: []
    priorityClassName: ""
  podMetadata: {labels: {}, annotations: {}}

  services:
    rw: {enabled: true, type: ClusterIP}
    ro: {enabled: true, type: ClusterIP}
    r:  {enabled: true, type: ClusterIP}

  podDisruptionBudget: {enabled: true}
  deletionPolicy: Retain    # Retain | Delete  (PVCs + generated Secrets)
  imagePolicy: AllowTags    # AllowTags | RequireDigest
```

### 1.2 Field rules (CEL unless noted)
| Field | Rule |
|---|---|
| `instances` | 1 ≤ n ≤ 9. |
| `image` | Required. Major version is parsed by the IM at runtime (from `postgres --version`), not from the tag; the operator stores it in `status.postgresMajor`. Changing to a different **major** is rejected at reconcile time with condition `UnsupportedChange` (CEL cannot see the binary). |
| `postgresUID/GID` | Default 999/999. Immutable. |
| `storage.size` | Increase allowed only if the StorageClass allows expansion; decrease rejected (`quantity(self) >= quantity(oldSelf)` — use `isQuantity` CEL library). |
| `storage.storageClassName`, `walStorage` presence | Immutable. |
| `postgresql.parameters` | Keys must not be in the **managed set** (02 §4.2). CEL: `self.all(k, !(k in [...]))`. Values are strings. |
| `postgresql.extensions` | Allowed only when `status.postgresMajor >= 18`; enforced at reconcile (`UnsupportedChange`). |
| `bootstrap` | Exactly one of `initdb`, `recovery`. Whole field immutable after creation. |
| `replication.synchronous.number` | `< instances` when mode=Quorum. |
| `ha.lease` | `renewDeadline + fenceTimeout < duration` and `retryPeriod * 2 <= renewDeadline`. Durations in [1s, 5m]. |
| `ha.crashHandling` | `1 <= maxRestarts <= 20`; `window` in [1m, 1h]; `backoff.initial <= backoff.max`, both in [1s, 5m]; `startTimeout` in [30s, 1h]. |
| `ha.quorum.voterRemovalDelay` | `>= 2 * lease.duration`. Mode may change at any time; the switch is a voter-set change (03 §3.5). |
| `primary.pin.policy == Strict` | Requires `acknowledgeStrictRisk: true`. |
| `primary.pin.instance` | Must name an existing instance — checked at reconcile (`PinTargetInvalid`). |
| `backup.storeRef` | Store must exist in namespace and be `Ready` — reconcile check. |
| `tls.mode` | Exactly one matching sub-block. |
| `deletionPolicy` | Default `Retain`. |
| `monitoring.diskThresholds` | `50 <= warningPercent < criticalPercent <= 99`. |
| `notifications` | `webhookSecretRef` required when the block is present; Secret must exist in the namespace (reconcile check, `NotificationsMisconfigured`). |

### 1.3 Status
```yaml
status:
  observedGeneration: 7
  phase: Healthy          # Creating | Healthy | Degraded | FailingOver | SwitchingOver | Upgrading | Restoring | Paused | Failed
  postgresMajor: 18
  currentPrimary: orders-1
  targetPrimary: orders-1
  timeline: 3
  quorum:                 # from IM status; see 03 §3
    mode: Peers
    term: 7
    voterEpoch: 3
    sustainQuorum: 2      # Qs
    acquireQuorum: 2      # Qa
    voters:
      - {name: lease, grantedTo: orders-1, renewedAgo: 1s}
      - {name: orders-1, grantedTo: orders-1, renewedAgo: 1s}
      - {name: orders-2, grantedTo: orders-1, renewedAgo: 2s}
  latestInstanceSerial: 4
  readyInstances: 3
  instances:
    - name: orders-1
      role: primary       # primary | replica | fenced | unknown (unknown = 3 failed status polls; never triggers failover by itself)
      ready: true
      node: kind-worker
      pvc: orders-1
      volumes:            # measured by the IM (statfs), works on any storage
        - {name: data, bytesTotal: 53687091200, bytesAvailable: 40265318400, inodesTotal: 3276800, inodesFree: 3270000}
        - {name: wal, bytesTotal: 10737418240, bytesAvailable: 9663676416, inodesTotal: 655360, inodesFree: 655000, pgWalBytes: 1073741824}
      timeline: 3
      lsn: {current: 0/3000060}
      pendingRestart: false
      imageID: docker.io/library/postgres@sha256:...
      toolsVersion: v0.4.0
    - name: orders-2
      role: replica
      ready: true
      lsn: {received: 0/3000060, replayed: 0/3000060}
      lagBytes: 0
      streaming: true
      syncState: quorum   # async | quorum | potential
  lastFailover: {time: ..., from: orders-0, to: orders-1, reason: LeaseExpired}
  archiving:
    lastArchivedWAL: 000000030000000000000003
    lastArchivedTime: ...
    lastFailedWAL: ""
    lastFailedTime: null
  firstRecoverabilityPoint: ...
  lastSuccessfulBackup: {name: orders-scheduled-20261015, time: ...}
  certificates: {serverExpiry: ..., caExpiry: ...}
  conditions:
    - type: Ready                 # all desired instances ready & primary writable
    - type: Progressing           # a rollout/switchover/scale in progress
    - type: PrimaryAvailable      # reasons incl. QuorumUnavailable, StrictPinWaiting
    - type: FailoverUnacknowledged # True while a PostgresPrimaryOverride exists (§12)
    - type: ReplicationHealthy    # all replicas streaming, lag < maxFailoverLag
    - type: ContinuousArchiving   # last archive attempt succeeded and is recent
    - type: DiskPressure          # any instance's data volume ≥ diskThresholds (bytes or inodes); reason Warning | Critical
    - type: WALDiskPressure       # same for the WAL volume, or pg_wal on the data volume
    - type: BackupHealthy         # last scheduled backup succeeded within schedule window
    - type: ConfigApplied         # IMs report config hash == desired hash, no pending restart
    - type: UnsupportedChange     # spec contains a change the operator refuses to apply
    - type: Paused
```
Printer columns: Instances, Ready, Primary, Phase, PG, Age.

### 1.4 Generated objects (names are API — don't change casually)
| Object | Name | Notes |
|---|---|---|
| Pod | `<cluster>-<serial>` | serial never reused |
| PVC | `<cluster>-<serial>`, `<cluster>-<serial>-wal` | |
| Service | `<cluster>-rw`, `<cluster>-ro`, `<cluster>-r` | selector on `pgkeeper.io/role` |
| Service (headless) | `<cluster>-instances` | per-pod DNS for replication |
| Lease | `<cluster>-primary` | coordination.k8s.io/v1 |
| Secret | `<cluster>-ca`, `<cluster>-server-tls`, `<cluster>-replication-tls`, `<cluster>-im-tls`, `<cluster>-app` (if generated), `<cluster>-superuser` (only if `spec.superuserAccess: true`) | |
| ConfigMap | `<cluster>-config` | rendered desired config + hash, read by IMs |
| ServiceAccount/Role/RoleBinding | `<cluster>-instance` | IM's narrow permissions (05 §6) |
| PDB | `<cluster>-primary`, `<cluster>-replicas` | |
| PostgresPrimaryOverride | `<cluster>-primary-override` | created/updated by the operator on failover or switchover; deleted only by a human (§12) |
| NetworkPolicy (optional) | `<cluster>-default` | Phase 26 |

Labels on everything: `app.kubernetes.io/name=postgresql`, `app.kubernetes.io/managed-by=pgkeeper`, `pgkeeper.io/cluster=<name>`; Pods/PVCs also `pgkeeper.io/instance=<pod>`, Pods also `pgkeeper.io/role=primary|replica`.

## 2. PostgresSwitchover (one-shot)
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresSwitchover
metadata: {name: orders-maint-20261015, namespace: team-a}
spec:
  clusterRef: {name: orders}
  targetInstance: orders-2        # optional: operator picks best candidate
  mode: Graceful                  # Graceful | Fast
  timeout: 60s
  ttlSecondsAfterFinished: 86400
status:
  phase: Completed                # Pending | Validating | Draining | Promoting | Rejoining | Completed | Failed | Rejected
  from: orders-1
  to: orders-2
  startTime: ...
  completionTime: ...
  writeUnavailableMillis: 1840
  message: ""
```
Rules: `spec` immutable (`self == oldSelf` on the whole spec). On completion of a human-requested switchover the operator creates/updates the cluster's PostgresPrimaryOverride to `status.to` (§12); operator-initiated switchovers only update an existing override. Only one non-terminal switchover per cluster — later ones go `Rejected` with reason `AnotherSwitchoverActive`. Rejected if `targetInstance` conflicts with a `Strict` pin, or isn't caught up within `timeout`. Owner reference to the cluster (garbage-collected with it).

## 3. PostgresRole
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresRole
metadata: {name: orders-reporting, namespace: team-a}
spec:
  clusterRef: {name: orders}
  roleName: reporting             # defaults to metadata.name with '-' → '_'; immutable
  login: true
  superuser: false                # CEL: must be false unless cluster allows (status check)
  createDB: false
  createRole: false
  inherit: true
  replication: false              # CEL: must be false (reserved for operator)
  bypassRLS: false
  connectionLimit: 20             # -1 = unlimited
  validUntil: "2027-01-01T00:00:00Z"
  memberOf: [readers]             # role names (managed or not)
  passwordSecretRef: {name: orders-reporting-pw, key: password}   # optional; absent = no password (cert/peer only)
  passwordRotation: {generate: true, length: 32}  # operator generates Secret if missing
  ensure: Present                 # Present | Absent
  deletionPolicy: Retain          # Retain | Drop  (Drop runs REASSIGN OWNED BY .. TO <cluster owner>; DROP OWNED; DROP ROLE)
status:
  applied: true
  passwordSecretVersion: "48213"  # resourceVersion of Secret last applied
  conditions: [Ready, Applied, DriftDetected]
```
Reserved names rejected by CEL: `postgres`, `streaming_replica`, `pgkeeper_*`, names starting with `pg_`.

## 4. PostgresDatabase
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresDatabase
metadata: {name: orders-analytics, namespace: team-a}
spec:
  clusterRef: {name: orders}
  databaseName: analytics          # immutable
  owner: reporting                 # role name
  encoding: UTF8                   # immutable
  locale: C.UTF-8                  # immutable
  template: template0              # immutable
  connectionLimit: -1
  extensions:
    - {name: pg_stat_statements, version: "", schema: public}
  schemas:
    - {name: staging, owner: reporting}
  deletionPolicy: Retain           # Retain | Drop
```
Rules: `databaseName` not in `postgres`, `template0`, `template1`. Extensions not shipped in the image (or mounted, PG18+) fail with `ExtensionUnavailable`.

## 5. PostgresGrant
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresGrant
metadata: {name: reporting-reads-analytics, namespace: team-a}
spec:
  clusterRef: {name: orders}
  role: reporting
  database: analytics
  privileges:
    database: [CONNECT, TEMPORARY]
    schemas:
      - name: public
        privileges: [USAGE]
        tables:    {privileges: [SELECT], scope: AllInSchema}     # AllInSchema | Listed
        sequences: {privileges: [USAGE, SELECT], scope: AllInSchema}
        functions: {privileges: [EXECUTE], scope: Listed, names: ["fn_report(int)"]}
        defaultPrivileges:
          forRole: app              # objects created by this role in the future
          tables: [SELECT]
          sequences: [USAGE, SELECT]
  withGrantOption: false
  revokeOnDelete: true
```
Semantics: the controller manages **exactly** the (role, object, privilege) tuples declared here — it grants missing ones and revokes ones previously granted by this CR that are no longer declared (tracked in status). It never revokes privileges it didn't grant (05 §3).

## 6. PostgresBackupStore
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresBackupStore
metadata: {name: s3-prod, namespace: team-a}
spec:
  type: S3                         # S3 | GCS | Azure | SFTP | PVC
  s3:
    bucket: pg-backups
    prefix: team-a/                # final path: <prefix>/<cluster>/<serverName>/
    region: ap-south-1
    endpoint: ""                   # for S3-compatible (SeaweedFS in tests)
    forcePathStyle: false
    credentials:
      secretRef: {name: s3-creds}  # keys: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
      # or: workloadIdentity: {serviceAccountAnnotations: {...}}
    storageClass: STANDARD_IA
    serverSideEncryption: aws:kms
  gcs:   {bucket: ..., prefix: ..., credentials: {secretRef | workloadIdentity}}
  azure: {container: ..., prefix: ..., storageAccount: ..., credentials: {...}}
  sftp:  {host: ..., port: 22, user: ..., path: ..., privateKeySecretRef: {...}, knownHostsSecretRef: {...}}  # knownHosts REQUIRED
  pvc:   {claimName: ..., path: /}  # RWX claim; mainly for tests
  compression: zstd                # lz4 | zstd | lzma | none
  encryption:
    openpgpKeySecretRef: {name: backup-pgp}   # optional client-side encryption
  uploadConcurrency: 4
  verifyOnCreate: true             # operator writes+reads+deletes a probe object
status:
  conditions: [Ready, Reachable]
  lastVerifiedTime: ...
```
SFTP without `knownHostsSecretRef` is rejected (no TOFU host-key trust).

## 7. PostgresBackup (one-shot)
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresBackup
metadata: {name: orders-adhoc-1, namespace: team-a}
spec:
  clusterRef: {name: orders}
  method: Full                     # Full | Delta
  target: PreferStandby            # overrides cluster default
  online: true
status:
  phase: Completed                 # Pending | Running | Completed | Failed
  instance: orders-2
  backupID: base_000000030000000000000005
  parentBackupID: ""               # for Delta
  startLSN: 0/5000028
  endLSN: 0/5000138
  timeline: 3
  startTime: ...
  stopTime: ...
  compressedSizeBytes: 123456789
  storeRef: {name: s3-prod}
```
Spec immutable. Deleting the CR does **not** delete the backup from storage unless `spec.deleteFromStoreOnDelete: true` (default false); retention handles storage cleanup.

## 8. PostgresScheduledBackup
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresScheduledBackup
metadata: {name: orders-nightly, namespace: team-a}
spec:
  clusterRef: {name: orders}
  schedule: "15 2 * * *"           # 5-field cron
  timeZone: Asia/Kolkata
  method: Delta                    # Delta falls back to Full when chain is full or broken
  fullEvery: 7                     # every Nth run is Full (also caps delta chain length)
  suspend: false
  backupsHistoryLimit: 14          # PostgresBackup CRs kept (storage retention is separate)
  concurrencyPolicy: Forbid
status:
  lastScheduleTime: ...
  lastSuccessfulTime: ...
  nextScheduleTime: ...
  runCount: 41
```

## 9. Recovery bootstrap (part of PostgresCluster)
```yaml
spec:
  bootstrap:
    recovery:
      source:
        storeRef: {name: s3-prod}
        serverName: orders          # path segment in the store (source cluster name)
        backupID: ""                # empty = latest valid before target
      target:                       # at most one of time | lsn | xid | name | immediate
        time: "2026-10-14T21:30:00+05:30"
        inclusive: false
        timeline: latest
  backup:
    storeRef: {name: s3-prod}       # if same store, cluster's serverName MUST differ from source.serverName
    serverName: orders-restored-20261015   # defaults to metadata.name
```
CEL: if `backup.storeRef.name == bootstrap.recovery.source.storeRef.name` then `backup.serverName != bootstrap.recovery.source.serverName` (ADR-009).

## 10. PostgresPooler (Phase 27, optional)
```yaml
spec:
  clusterRef: {name: orders}
  instances: 2
  type: rw                          # rw | ro
  image: <pinned pgbouncer image — selected at phase start>
  poolMode: transaction
  parameters: {max_client_conn: "1000", default_pool_size: "20"}
  pauseOnSwitchover: true
```

## 11. Versioning plan
- `v1alpha1`: breaking changes allowed, but each must update this file, the CRD changelog (`docs/api-changelog.md`) and the sample manifests in the same PR.
- `v1beta1` (after Phase 28): requires a conversion webhook; the webhook phase is added then.

## 12. PostgresPrimaryOverride (operator-created, human-deleted)
```yaml
apiVersion: pgkeeper.io/v1alpha1
kind: PostgresPrimaryOverride
metadata:
  name: orders-primary-override     # exactly one per cluster
  namespace: team-a
  ownerReferences: [{kind: PostgresCluster, name: orders, controller: true}]
spec:
  clusterRef: {name: orders}
  instance: orders-3                # who must be primary while this object exists
status:
  reason: Failover                  # Failover | Switchover
  since: ...
  history:                          # appended on every update (capped at 20)
    - {time: ..., from: orders-1, to: orders-2, reason: Failover}
    - {time: ..., from: orders-2, to: orders-3, reason: Failover}
```
Rules (ADR-017):
- Created or updated **only by the operator**: created/updated on every automatic failover and on completion of every human-requested PostgresSwitchover; operator-initiated switchovers (rolling update, eviction) only update an existing one; switchbacks to the pin create nothing. The operator never deletes it; a human does, as the acknowledgement.
- Precedence for `status.targetPrimary`: override > `spec.primary.pin` > candidate selection (03 §5.3).
- While it exists: cluster condition `FailoverUnacknowledged=True`.
- On deletion: if a `Preferred` pin names an instance that isn't primary, the operator starts a Graceful switchover to it once it is healthy and lag < 16 MiB (`Progressing reason=SwitchbackWaiting` meanwhile); otherwise nothing moves.
- Never created under a `Strict` pin (Strict never fails over).
- `spec.instance` names an instance that no longer exists → ignored for precedence, condition `UnsupportedChange reason=OverrideTargetInvalid`; still deleted only by a human.
- Printer columns: Cluster, Instance, Reason, Age.
