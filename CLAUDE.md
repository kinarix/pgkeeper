# CLAUDE.md — pgkeeper

Kubernetes operator for highly available PostgreSQL on **unmodified official `postgres` images**: CRD-driven clusters, streaming replication, lease-based safe failover, switchover/pinning, WAL-G backups with PITR, role/database/grant CRDs, metrics, and a dashboard with live access logs. Go, kubebuilder/controller-runtime. Tested locally on kind and k3d.

> Repo `github.com/kinarix/pgkeeper` (Go module path), images `ghcr.io/kinarix/pgkeeper-{operator,tools,dashboard}`, CRD API group `pgkeeper.io`. These names are final; the API group is baked into every CRD, label and annotation.

## Read first
| When | Read |
|---|---|
| Starting any work | `docs/specs/09-phases.md` (find the current phase; its scope and acceptance are your contract) |
| Why things are the way they are | `docs/specs/00-overview.md` (challenged requirements C1–C9) and `docs/adr/` (one file per decision; index in `docs/adr/README.md`) |
| Claiming a feature closes a gap vs CNPG/others | `docs/adr/015-build-to-close-existing-gaps.md` (gap ledger) |
| Touching CRD types | `docs/specs/01-api.md` |
| Touching `cmd/instance` or `internal/instance` | `docs/specs/02-instance-manager.md` |
| Touching failover, lease, switchover, replication, rollouts | `docs/specs/03-ha.md` — **invariants table first**; then `docs/specs/11-ha-scenarios.md` (update any scenario your change affects) |
| Backups/restore | `docs/specs/04-backup-restore.md` |
| Roles/DBs/grants/HBA/TLS/RBAC | `docs/specs/05-access-control.md` |
| Metrics/logs/dashboard | `docs/specs/06-observability-dashboard.md` |
| Controller patterns, drift, multi-namespace | `docs/specs/07-reconciliation-and-tenancy.md` |
| Tests, local clusters, Makefile | `docs/specs/08-testing-and-makefile.md` |
| Unfamiliar term | `docs/specs/10-glossary.md` |

**The specs are the source of truth.** If code must deviate, update the spec in the same change and say why. If a spec is ambiguous or contradicts another spec, stop and ask rather than guessing.

## Working rules
1. **One phase at a time.** Only implement what the current phase lists. Don't pre-build later phases "while you're there". Leave `TODO(Pn): ...` with the phase number for deliberate deferrals.
2. **Phase is done only when `make accept-pN` passes on kind and k3d** plus the Definition of Done in 08 §6. Then tick the phase in `09-phases.md`.
3. **Small commits**, each building and passing `make verify lint test-unit`.
4. **Test first for safety logic.** For anything in `internal/ha`, the lease loop, fencing or promotion: write/extend the model test (rapid) and unit tests before the implementation.
5. **Never weaken an invariant (03 §1) to make a test pass.** If an invariant seems wrong, stop and raise it.
6. **Verify external facts** (tool versions, WAL-G flags, Postgres GUC names/values per major) against upstream docs at the start of the phase that needs them; pin what you verified in the Makefile/go.mod and note it in the PR.
7. Ask before: adding a new dependency with cgo, adding a new CRD or CRD field not in 01-api.md, changing generated object names (01 §1.4), changing default timings in `ha`.

## Safety invariants (short form — full table in 03 §1)
- At most one writable primary: Postgres runs read-write only while its IM holds a **sustain quorum** of the quorum lease — the `<cluster>-primary` Lease **or** enough peer votes (03 §3, ADR-016); on doubt the IM fences with **immediate** stop.
- Every acquire quorum must intersect every sustain quorum (`Qa + Qs > n`, joint quorums during voter-set changes); a voter never grants to two candidates at once (I7).
- `renewDeadline + fenceTimeout < leaseDuration` — enforced by CEL; never change defaults without updating model tests.
- Promotion requires an acquire quorum (the Lease **and** `Qa` instance votes) **and** `status.targetPrimary == self`.
- Former primaries rejoin only after the timeline check / `pg_rewind`.
- Never delete the current primary's PVC or the only PVC with the most advanced LSN.
- Never let two clusters archive to the same store path.
- Only the operator writes CR `status`.

## Architecture in 60 seconds
- **Operator** (`cmd/operator`): controllers for PostgresCluster, PostgresSwitchover, PostgresPrimaryOverride (operator-created, human-deleted; ADR-017), PostgresRole, PostgresDatabase, PostgresGrant, PostgresBackupStore, PostgresBackup, PostgresScheduledBackup. Manages **Pods + PVCs directly (no StatefulSets)**, Services `-rw/-ro/-r`, Secrets, ConfigMap, Lease, PDBs, RBAC. Decides *who* should be primary.
- **Instance manager** (`cmd/instance`, binary `pgkeeper-instance`): PID 1 in every Postgres container, delivered via image volume (init-copy fallback). Bootstraps, renders config, supervises postmaster, holds the lease and fences, promotes/demotes, runs WAL-G, serves probes (8001), mTLS API (8000), metrics (9187), and re-emits Postgres jsonlog as categorised JSON on stdout.
- **Dashboard** (`cmd/dashboard`): OIDC login, all K8s access by **impersonating the user**, live state via SSE, live logs via pod-log follow.
- **Tools image**: `FROM scratch` with static `pgkeeper-instance` + `wal-g` (built from pinned commit, `CGO_ENABLED=0`).

## Repository layout
```
api/v1alpha1/                 CRD Go types, CEL markers, conditions.go
cmd/operator/  cmd/instance/  cmd/dashboard/  cmd/kubectl-pgkeeper/ (P28)
internal/controller/<kind>/   one package per controller
internal/resources/           pure builders: desired Pod/PVC/Service/Secret/… from a cluster spec (no client calls)
internal/ha/                  candidate selection, lease timing math, switchover/failover state machines (pure, heavily tested)
internal/lease/               quorum lease used by IM: voter interface, K8s Lease voter, instance voter (P10b), fake
internal/instance/            IM: supervisor, bootstrap, config render, fencing, api server, logpipe, metrics
internal/imclient/            operator→IM mTLS client (+ fake for envtest)
internal/sqlplan/             role/db/grant diff planners (pure) + executors (IM side)
internal/backup/              BackupEngine interface, walg implementation
internal/pki/                 CA and cert issuance/rotation
internal/scram/               SCRAM-SHA-256 verifier
internal/dashboard/           server, oidc, impersonation, sse; web/ (SPA source), web/dist (embedded)
config/                       kustomize: crd, rbac, manager, dashboard, samples, overlays (all-ns, list-ns)
hack/                         kind/, k3d/, infra/ (SeaweedFS, fake-gcs, Azurite, SFTP, Dex), chaos/
test/e2e/chainsaw/            pN-<name>/ declarative tests
test/e2e/go/                  measured/SQL e2e, ledger harness (test/e2e/go/ledger)
test/im/                      testcontainers IM integration
docs/specs/                   specs (source of truth)
docs/adr/                     architecture decision records (NNN-slug.md; never renumber, supersede instead)
docs/api-changelog.md         every CRD change
```

## Commands (all via Make; tools live in ./bin)
```
make help                  list targets
make dev                   cluster-up + infra-up + install + build + load + deploy-dev + samples
make verify lint test      before every commit (verify = regenerate and fail on diff)
make test-im               IM against real postgres:16/17/18 containers
make e2e-smoke             quick e2e on current local cluster
make accept-pN             phase N acceptance suite
make CLUSTER_PROVIDER=k3d cluster-up   use k3s instead of kind
make psql CLUSTER=orders NS=team-a
make logs LOGS=instance CLUSTER=orders
make artifacts             diagnostics bundle after a failure
```
Never run e2e/infra targets against a non-local context (Makefile guards this; don't bypass with `ALLOW_NON_LOCAL=1` unless asked).

## Go conventions
- Go version from `go.mod`; controller-runtime/controller-gen versions pinned (08 §2).
- Errors: `fmt.Errorf("doing x: %w", err)`; no `panic` outside `main`; sentinel errors in package `errors.go`.
- Logging: `logr` from context (`log.FromContext(ctx)`), key/value pairs, keys in lowerCamel (`cluster`, `instance`, `lsn`). **Never log secrets, passwords, verifiers, connection strings with passwords, notification webhook URLs, or full SQL containing credentials.**
- Contexts with deadlines on every network/SQL call.
- Builders in `internal/resources` are pure functions returning objects — unit-test them with golden files (`testdata/*.golden.yaml`, `-update` flag).
- Reconcilers: idempotent, no sleeps, SSA with field manager `pgkeeper-operator`, status via subresource only when changed, conditions via `meta.SetStatusCondition`, events for human-relevant transitions (07 §1).
- No `sort` package (depguard) — use `slices`/`maps`.
- Time: inject a `clock.Clock` (k8s.io/utils/clock) in `ha`, `lease`, `instance` — no direct `time.Now()` there, so tests control time.

## Postgres conventions
- Identifiers via `pgx.Identifier{...}.Sanitize()`; values via bind parameters. String-built SQL with user input is a review blocker (lint rule).
- SQL runs only inside the IM over the unix socket; the operator never connects to Postgres directly (except the write-availability probe user, P9).
- Version-specific behaviour (PG16/17/18) lives behind a `pgversion` capability table — no scattered `if major >= 17`.
- Users may not set managed GUCs (02 §4.2); keep the list in one place (`internal/config/managed.go`) used by both CEL generation docs and runtime checks.

## Testing conventions
- Unit tests table-driven, `t.Parallel()` where safe, `-race` always.
- envtest: use `Eventually`/`Consistently` with explicit timeouts; never `time.Sleep`.
- e2e: each test in its own namespace; clean up on success, keep and dump on failure.
- Flaky test = bug. Fix or quarantine with an issue link within the same PR; never retry-until-green.
- HA changes require a ledger chaos run (08 §3.6) with the report in the PR.

## Don'ts
- Don't modify or wrap the official Postgres image; don't use `docker-entrypoint.sh`.
- Don't use StatefulSets, Patroni, or smart-mode shutdown on the primary.
- Don't add arbitrary SQL execution endpoints to the IM or dashboard.
- Don't add FTP support (use SFTP) — see 00 C2.
- Don't restore in place — PITR always creates a new cluster.
- Don't cache all Secrets/Pods cluster-wide — label-restricted caches only.
- Don't commit generated files out of sync (`make verify`).
