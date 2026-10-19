---
id: ADR-005
title: "ADR-005 — Operator elects, IM acquires lease and promotes"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P8, P9, P10]
topics: [election, promotion]
references: [00-overview, 03-ha, 07-reconciliation-and-tenancy, ADR-004]
related: "00-overview §4 (Division of authority), 03 §3.4, §5"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-005 — Operator elects, IM acquires lease and promotes

## Context
Someone must decide *which* instance becomes primary; safety is already guaranteed by the lease (ADR-004).

## Decision
The operator chooses the target (`status.targetPrimary`); the named instance's IM acquires the lease and promotes. If the operator is down, failover is delayed, never unsafe.

## Alternatives rejected
- **Decentralised election among IMs:** rejected for v1 complexity; can be added later since the lease already guarantees safety.

## Consequences
Failover liveness depends on the operator being up; primaries keep renewing their own leases during operator outages (07 §5).
