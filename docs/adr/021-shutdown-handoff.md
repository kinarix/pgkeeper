# ADR-021 — SIGTERM on the primary hands over like a switchover

- Status: Accepted
- Date: 2026-10-16
- Related: 02 §5.4, 03 §7, §7.1, §9; ADR-017, ADR-019

## Context
Previously, SIGTERM on the primary (pod delete, eviction, node shutdown) did a fast stop and released the lease with `release-reason=Shutdown`. The operator then ran an ordinary failover. Under async replication that can lose recent commits and need `pg_rewind`, even though the old primary shut down cleanly and knew exactly where its WAL ended.

## Decision
- On SIGTERM outside a switchover, the primary IM performs the switchover demote step on its own:
  1. fast stop (bounded by `terminationGracePeriodSeconds − 5 s`, then immediate);
  2. read the shutdown checkpoint LSN;
  3. release the lease with `release-reason=Shutdown` and `pgkeeper.in/shutdown-lsn` (omitted if it had to escalate to immediate).
- The operator promotes the best candidate whose received LSN reaches the shutdown LSN within `min(10 s, lease.duration)`, with no expiry wait. That means zero lost commits and no rewind. If no candidate reaches it in time, or there's no `shutdown-lsn`, a normal failover follows.
- For the override (ADR-017) this counts as an operator-initiated switchover: it updates an existing override but never creates one.
- The node-drain path still pre-empts this: the operator switches over when the primary's node is cordoned (03 §9 step 5). The handoff covers everything else.

## Alternatives rejected
- **Keep fast stop + plain failover:** avoidable data loss and rewinds on routine pod deletions.

## Consequences
- `release-reason=Shutdown` with `shutdown-lsn` is a handoff, not a failure (03 §5.1).
- Phase 9 acceptance gains "delete the primary pod under ledger load → 0 lost acked writes, no rewind" (09).
