# ADR-009 — PITR only into a new cluster; archive path collision is rejected

- Status: Accepted
- Date: 2026-10-15
- Related: 00-overview C7, 01 §9, 04 §2, §7, invariant I6

## Context
In-place "rewind the production DB" is a footgun, and two timelines archiving to one path corrupt the archive.

## Decision
PITR always bootstraps a **new** cluster from a backup store. The new cluster must archive to a different path than its source (CEL + runtime ownership check).

## Alternatives rejected
- **In-place restore.**

## Consequences
Restoring requires capacity for a second cluster; cut-over is the user's responsibility.
