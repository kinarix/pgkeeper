# ADR-005 — Operator elects, IM acquires lease and promotes

- Status: Accepted
- Date: 2026-10-15
- Related: 00-overview §4 (Division of authority), 03 §3.4, §5

## Context
Someone must decide *which* instance becomes primary; safety is already guaranteed by the lease (ADR-004).

## Decision
The operator chooses the target (`status.targetPrimary`); the named instance's IM acquires the lease and promotes. If the operator is down, failover is delayed, never unsafe.

## Alternatives rejected
- **Decentralised election among IMs:** rejected for v1 complexity; can be added later since the lease already guarantees safety.

## Consequences
Failover liveness depends on the operator being up; primaries keep renewing their own leases during operator outages (07 §5).
