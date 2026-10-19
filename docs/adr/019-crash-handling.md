---
id: ADR-019
title: "ADR-019 — Primary crash: restart in place, fail over only on a crash loop (configurable)"
type: adr
status: accepted
decided: 2026-10-16
version: 0.2.0
updated: 2026-10-19
phases: [P10]
topics: [crash-handling, failover]
references: [01-api, 02-instance-manager, 03-ha, 08-testing-and-makefile, 11-ha-scenarios, ADR-017]
related: "02 §5.4, 03 §3.3, §3.7, §5.1, 11 §4, §22"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-019 — Primary crash: restart in place, fail over only on a crash loop (configurable)

## Context
The specs contradicted each other:
- 02 §5.4: restart the postmaster with backoff; fail over only after 5 crashes in 5 min.
- 03 §3.3: the holder steps down as soon as the postmaster isn't alive, so a single crash triggers failover.

Trade-offs:
- **Restart in place:** usually faster than failover (crash recovery replays WAL since the last checkpoint). It loses no acknowledged writes, since all committed WAL is on the primary's disk. It avoids a timeline change and `pg_rewind`.
- **Failing over** on every crash: costs ≤ 30 s, loses up to the replication lag in async mode, and creates a `PostgresPrimaryOverride` to acknowledge (ADR-017).
- **Repeated crashes** (OOM, disk full, corrupted state) mean restarting won't help, so failover is the right answer then.
- **Crash recovery can be slow** (large `max_wal_size`, slow disks). Without a bound, writes stay down indefinitely.

## Decision
1. **Default: restart in place.** On a postmaster crash, the primary IM keeps holding the lease (it keeps renewing votes) and restarts Postgres with exponential backoff.
2. **Crash loop → failover.** If `maxRestarts` crashes happen within `window`, the IM stops restarting, reports `CrashLoop`, and releases the lease with `release-reason=CrashLoop`. The operator fails over without waiting for expiry (03 §5.1).
3. **Recovery timeout → failover.** If a restarted Postgres doesn't accept connections within `startTimeout`, the IM gives up the same way, with `release-reason=RecoveryTimeout`.
4. **What counts as a crash:**
   - the postmaster exiting without being asked;
   - an in-place reinitialisation after a backend crash (Postgres logs "all server processes terminated; reinitializing", e.g. after a backend OOM kill), so repeated OOMs also end in a crash loop.

   Intentional stops (fence, switchover, SIGTERM, operator restart) never count.
5. **Configurable** per cluster via `spec.ha.crashHandling`:
   ```yaml
   crashHandling:
     policy: RestartInPlace    # RestartInPlace | FailoverImmediately
     maxRestarts: 5            # crashes within window before CrashLoop
     window: 5m
     backoff: {initial: 1s, max: 30s}
     startTimeout: 2m          # restarted primary must accept connections within this
   ```
   `FailoverImmediately`: any crash on the primary makes the IM release the lease (`release-reason=Crash`) without restarting, so the operator fails over at once.
6. **No eligible target** (single instance, `Strict` pin whose pinned instance is this one, or `QuorumUnavailable`/`NoEligibleCandidate`): releasing the lease can't produce a new primary. The IM keeps restarting at `backoff.max`, keeps holding the lease, and reports `CrashLoop` (condition + events + webhook Critical). The operator publishes `failoverPossible` in `<cluster>-config`, which the IM already watches (02 §4.1). If the API server is unreachable, the IM keeps the last value.
7. **Replicas** always restart in place. A crash loop on a replica is reported, never escalated, and it is excluded from failover candidates while in `CrashLoop` (03 §5.3 step 1).
8. **Safety is unchanged.** Postgres down accepts no writes. The IM restarts Postgres as primary only while it still holds a sustain quorum. The deadline timer stays armed during crash recovery, so a lease loss mid-recovery fences as usual. No HA timing defaults change.

## Alternatives rejected
- **Always fail over** (previous 03 §3.3): an outage plus a timeline change and an override to acknowledge, for faults that a restart fixes in seconds; and data loss under async replication.
- **Always restart, never escalate:** a deterministic crash (disk full, OOM on every start) keeps writes down forever.
- **Liveness-probe-driven restarts:** kubelet restarts the whole container, including the IM, losing state and taking longer. The IM is better placed to decide (02 §6: liveness never fails for Postgres health).

## Consequences
- New CRD field `spec.ha.crashHandling` (CEL rules in 01 §1.2) and release reasons `Crash`, `RecoveryTimeout`.
- The holder loop's `healthyLocal` reflects the crash policy, not raw postmaster liveness (03 §3.3). The model tests gain "postmaster crashes/restarts while holding the lease" (08 §3.2).
- 11 §4 and §22 now describe settled behaviour; the open-issue rows are removed.
