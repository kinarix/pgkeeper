# Architecture Decision Records

One file per decision. Specs (`docs/specs/`) say *what* the system does; ADRs record *why* a choice was made and what was rejected. Specs reference decisions as `ADR-NNN`.

## Rules
- Numbers are never reused or renumbered. File name: `NNN-short-slug.md`.
- An accepted ADR is not edited to change its decision. To change course, write a new ADR with `Supersedes: ADR-NNN` and set the old one's status to `Superseded by ADR-MMM`.
- Typos, links and "verified on <date>" updates may be edited in place.
- A decision that changes spec behaviour updates the spec in the same change (CLAUDE.md: specs are the source of truth).

## Index
| ADR | Decision | Status |
|---|---|---|
| [001](001-go-kubebuilder.md) | Go + kubebuilder/controller-runtime | Accepted |
| [002](002-pods-pvcs-no-statefulset.md) | Pods + PVCs managed directly, no StatefulSet | Accepted |
| [003](003-instance-manager-pid1.md) | Instance manager as PID 1 inside the official image, injected via image volume / init copy | Accepted |
| [004](004-single-lease-self-fence.md) | Single Lease is the only split-brain guard; IM self-fences with immediate stop | Superseded by ADR-016 |
| [005](005-operator-elects-im-promotes.md) | Operator elects, IM acquires lease and promotes | Accepted |
| [006](006-walg-backup-engine.md) | WAL-G as v1 backup engine behind a `BackupEngine` interface with sidecar engines later | Accepted |
| [007](007-pin-field-switchover-crd.md) | Pin = spec field; Switchover = CRD | Accepted |
| [008](008-cel-no-webhook.md) | CRD validation via OpenAPI + CEL, no admission webhook until conversion is needed | Accepted |
| [009](009-pitr-new-cluster-only.md) | PITR only into a new cluster; archive path collision is rejected | Accepted |
| [010](010-dashboard-impersonation.md) | Dashboard authorizes via K8s impersonation | Accepted |
| [011](011-dashboard-logs-pod-log-api.md) | Dashboard live logs via K8s pod-log API (follow) in v1 | Accepted |
| [012](012-seaweedfs-local-s3.md) | Local S3 for tests: SeaweedFS | Accepted |
| [013](013-debian-images-only.md) | Debian-based official images only in v1 | Accepted |
| [014](014-scram-verifiers.md) | Role passwords delivered as SCRAM-SHA-256 verifiers computed by the operator | Accepted |
| [015](015-build-to-close-existing-gaps.md) | Build pgkeeper (not adopt CNPG) to close gaps in existing operators; maintain a gap ledger | Accepted |
| [016](016-quorum-lease.md) | Quorum lease: primary survives on the K8s Lease *or* its peers; promotion needs both | Accepted |
| [017](017-primary-override.md) | Failover creates a PostgresPrimaryOverride; only a human deletes it | Accepted |
| [018](018-health-monitoring-notifications.md) | Pull-based health, IM-measured disk, shipped alert rules, optional HA webhook | Accepted |
| [019](019-crash-handling.md) | Primary crash: restart in place, fail over only on a crash loop (configurable) | Accepted |
| [020](020-archive-mode-always.md) | `archive_mode = always` with dedup, so failover leaves no archive gap | Accepted |
| [021](021-shutdown-handoff.md) | SIGTERM on the primary hands over like a switchover | Accepted |
| [022](022-user-secrets-uncached.md) | User-referenced Secrets: metadata-only watch + uncached reads | Accepted |

## Template
```markdown
# ADR-NNN — <decision in one line>

- Status: Proposed | Accepted | Superseded by ADR-MMM
- Date: YYYY-MM-DD
- Supersedes: — | ADR-MMM
- Related: specs §…, challenged requirement C…

## Context
## Decision
## Alternatives rejected
## Consequences
```
