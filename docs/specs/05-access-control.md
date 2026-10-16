# 05 — Access Control: Roles, Databases, Grants, pg_hba, TLS, RBAC

## 0. Principles
- Declarative and **scoped**: a controller manages only objects it created (tracked by a `COMMENT` marker and status), never "everything in the database". Users can still create unmanaged roles manually; the operator ignores them (and reports them in a read-only inventory on the dashboard).
- SQL is executed by the **primary IM** over the local unix socket as `postgres` (peer auth). The operator sends a structured desired state; the IM computes and applies the diff. There is no arbitrary-SQL endpoint.
- All identifiers are quoted with `pgx.Identifier{...}.Sanitize()`; all values are bind parameters or `quote_literal`-equivalent. No string concatenation of user input into SQL — lint rule + review checklist.
- Every applied change is logged by the IM as a structured audit event (`category: audit`, `actor: <CR namespace/name>`), never including secret values.

## 1. Roles (`PostgresRole`)
### 1.1 Reconcile
1. Operator: resolve cluster primary; read `passwordSecretRef` (or generate Secret if `passwordRotation.generate`); compute **SCRAM-SHA-256 verifier** (`SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>`) with a random salt (ADR-014).
2. Call IM `/v1/sql/roles/reconcile` with `{name, attributes, memberOf, verifier|null, validUntil, connectionLimit, ensure, ownerRef}`.
3. IM, in one transaction with `SET LOCAL log_statement = 'none'` and `SET LOCAL pgaudit.log = 'none'` (if loaded):
   - `CREATE ROLE` if missing, else `ALTER ROLE` only for attributes that differ (read from `pg_authid`/`pg_roles`);
   - password: only if `rolpassword` differs from the verifier **or** the Secret's resourceVersion changed (IM can't compare plaintext; operator tracks `status.passwordSecretVersion`);
   - membership: `GRANT`/`REVOKE` for declared `memberOf` diff; memberships not declared and not previously granted by this CR are left alone;
   - `COMMENT ON ROLE x IS 'pgkeeper:<namespace>/<name>:<uid>'` — ownership marker.
4. If the role exists without our marker → condition `Applied=False reason=RoleExistsUnmanaged` (no takeover unless annotation `pgkeeper.io/adopt: "true"`).

### 1.2 Drift
- Periodic resync (default 10 min, plus on every Secret change via watch) re-runs reconcile; any change applied counts as drift → `DriftDetected=True` with a short description, event, metric `pgkeeper_drift_corrections_total{kind="role"}`.

### 1.3 Deletion
- `ensure: Absent` or CR deletion with `deletionPolicy: Drop`: terminate the role's sessions (`pg_terminate_backend`), `REASSIGN OWNED BY r TO <cluster owner>` in **every** database, `DROP OWNED BY r` in every database, `DROP ROLE r`. `Retain`: remove the marker comment only.

### 1.4 Built-in roles (operator-owned, not CRD-managed)
| Role | Purpose | Auth |
|---|---|---|
| `postgres` | superuser | local peer only; remote only if `spec.superuserAccess: true` (password from `<cluster>-superuser`) |
| `streaming_replica` | replication | client cert only |
| `pgkeeper_monitor` | metrics | local peer; member of `pg_monitor` |
| bootstrap owner (e.g. `app`) | app owner | SCRAM, Secret `<cluster>-app` |

## 2. Databases (`PostgresDatabase`)
- IM: `CREATE DATABASE` (outside transaction) with owner/encoding/locale/template; later `ALTER DATABASE ... OWNER TO`, `CONNECTION LIMIT`; per-database connection for `CREATE EXTENSION IF NOT EXISTS ... SCHEMA ... VERSION ...` / `ALTER EXTENSION ... UPDATE TO`, `CREATE SCHEMA IF NOT EXISTS ... AUTHORIZATION ...`.
- Marker: `COMMENT ON DATABASE`.
- Immutable fields changing on an existing DB → `UnsupportedChange`.
- Deletion `Drop`: refuse if active connections unless annotation `pgkeeper.io/force-drop: "true"` (then `DROP DATABASE ... WITH (FORCE)`).

## 3. Grants (`PostgresGrant`)
- Desired set = expansion of the spec into tuples `(objectType, objectIdentity, privilege, grantOption)` for the role. `scope: AllInSchema` expands at reconcile time to current objects **and** is re-expanded on every resync (new tables get grants within one resync; for immediate effect users set `defaultPrivileges`).
- Actual set = `aclexplode()` over `pg_database.datacl`, `pg_namespace.nspacl`, `pg_class.relacl`, `pg_proc.proacl`, `pg_default_acl` filtered to `grantee = role`.
- Applied = `status.appliedTuples` (hash-compressed list stored in a ConfigMap `pgkeeper-grant-<uid>` if > 1000 tuples).
- Plan: `GRANT` desired − actual; `REVOKE` (appliedTuples − desired) ∩ actual. Never revoke tuples we never applied.
- One transaction per database. Errors on individual objects (dropped concurrently) are retried once, then reported.
- `ALTER DEFAULT PRIVILEGES FOR ROLE <forRole> IN SCHEMA s GRANT ... TO <role>` for `defaultPrivileges`.

## 4. pg_hba
Rendered by IM, top to bottom (first match wins):
```
# 1. operator-reserved
local   all          postgres,pgkeeper_monitor              peer
hostssl replication  streaming_replica  <podCIDR|0.0.0.0/0> cert
host    all          streaming_replica  all                 reject
# 2. user rules from spec.postgresql.hba (validated: no 'trust', no 'password'/'md5' unless allowWeakAuth: true; PG19 deprecates md5)
hostssl all          all                10.0.0.0/8          scram-sha-256
# 3. default tail
hostssl all          all                all                 scram-sha-256
host    all          all                all                 reject     # no non-TLS remote connections
```
- CEL rejects `method: trust` unless the spec has `allowTrust: true` (tests only).
- Changing HBA = reload, no restart.

## 5. TLS
| Mode | Behaviour |
|---|---|
| `OperatorManaged` (default) | Per-cluster self-signed CA (ECDSA P-256, 10 y) in `<cluster>-ca`; server cert (SANs: all service names, `*.<cluster>-instances.<ns>.svc`, short names) 90 d; replication client cert; IM API cert; operator, dashboard and instance (`pgkeeper-instance`, for quorum-lease votes, 03 §3.2) client certs signed by the same CA. Rotation at 2/3 lifetime; IM reloads Postgres (`ssl_*` files reread on SIGHUP). |
| `CertManager` | Operator creates `Certificate` resources against the given issuer; waits for Ready Secrets. |
| `UserProvided` | Uses given Secrets; operator only validates SANs/expiry and raises `CertificateExpiringSoon` (< 14 d). |
- `ssl_min_protocol_version = TLSv1.2` (configurable up), `ssl_prefer_server_ciphers = on`.
- Clients get a ready connection Secret per managed role (`<cluster>-<role>-conn`, opt-in) with `uri`, `host`, `port`, `dbname`, `user`, `password`, `sslrootcert` (CA cert) — for app consumption (`envFrom`).

## 6. Kubernetes RBAC
### 6.1 Operator ServiceAccount
Cluster-scoped install (watch all namespaces): ClusterRole with:
- `pgkeeper.io/*` all verbs + status/finalizers
- pods, pvcs, services, secrets, configmaps, serviceaccounts, events: create/get/list/watch/update/patch/delete
- roles, rolebindings (to create per-cluster IM roles): create/get/list/watch/update/patch/delete + `bind`/`escalate` **only** on the IM ClusterRole template via `resourceNames`
- leases (coordination.k8s.io): get/list/watch/update/patch/create/delete
- poddisruptionbudgets, networkpolicies: manage
- nodes: get/list/watch (failure detection)
- `cert-manager.io` certificates (optional), `monitoring.coreos.com` podmonitors (optional)
- Secrets referenced by `spec.notifications.webhookSecretRef` and `--notify-webhook-secret`: get/watch (user-referenced and unlabelled — same cache issue as role/store Secrets, 07 §2 vs §4.3)
Namespace-scoped installs (07 §4) bind the same rules via Roles in each watched namespace.

### 6.2 Instance ServiceAccount `<cluster>-instance` (per cluster)
- `get/watch` on its own `postgresclusters/<cluster>` (resourceNames)
- `get/watch` on ConfigMap `<cluster>-config` and the cluster's Secrets it needs (resourceNames list)
- `get/update/patch` on Lease `<cluster>-primary` (resourceNames); `create` leases (cannot be restricted by resourceNames — acceptable, or pre-create the Lease from the operator and omit `create`: **do this**)
- Nothing else. No pod patching, no listing secrets.

### 6.3 Dashboard ServiceAccount
- `impersonate` on users/groups/serviceaccounts (scope by `resourceNames` if a fixed group set is used)
- Everything else is evaluated against the **impersonated** user's RBAC. Provided aggregated ClusterRoles for users:
  - `pgkeeper-viewer`: get/list/watch pgkeeper CRs + pods/log in namespace
  - `pgkeeper-operator-user`: viewer + create PostgresSwitchover/PostgresBackup + delete PostgresPrimaryOverride (acknowledge failover → may trigger a switchback, ADR-017)
  - `pgkeeper-admin`: all pgkeeper CRs
  (Optionally aggregated into `view`/`edit`/`admin`.)

### 6.4 Admission policies (ValidatingAdmissionPolicy, shipped as optional manifests)
- Restrict who may change `PostgresCluster.spec.primary` (pin) — C5.
- Forbid `PostgresRole.spec.superuser: true` except for a named group.
- Forbid `deletionPolicy: Delete` on clusters in namespaces labelled `env=prod`.

## 7. Network
- Optional per-cluster NetworkPolicy (Phase 26): ingress 5432 from namespaces/pods selected in `spec.networkPolicy.allowedClients`; 5432 replication between instances; 8000 from operator & dashboard namespaces and between instances of the same cluster (quorum-lease votes); 8001 from kubelet (node CIDR — CNI-specific; document); 9187 from monitoring namespace. Egress: DNS, API server, backup store endpoints, instances. The **operator** additionally needs egress to configured notification webhook endpoints (06 §2.5).
