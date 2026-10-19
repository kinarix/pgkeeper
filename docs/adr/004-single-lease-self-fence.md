---
id: ADR-004
title: "ADR-004 — Single Lease is the only split-brain guard; IM self-fences with immediate stop"
type: adr
status: superseded
superseded_by: ADR-016
status_note: "the single-guard principle is kept; the single K8s Lease store is replaced by a quorum lease"
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: []
topics: [lease, fencing]
references: [00-overview, 03-ha]
related: "00-overview C4, 03 §1 (I1, I1a), §3"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-004 — Single Lease is the only split-brain guard; IM self-fences with immediate stop

## Context
A July 2026 chaos study (Coroot) showed a default CNPG cluster keeping an isolated old primary writable for 177 s after its replacement was promoted, because promotion and fencing ran on two independent timers and pooled client connections never reconnected.

## Decision
A single `<cluster>-primary` Lease is the only safety mechanism. The holder self-fences with an *immediate* stop strictly before the lease can be acquired by anyone else. Timers are derived from one another and validated by CEL (`renewDeadline + fenceTimeout < duration`).

## Alternatives rejected
- **Two independent timers** (promotion vs graceful shutdown): rejected after the Coroot 2026 findings.

## Consequences
- Immediate stop kills client sessions, so pooled connections reconnect via `-rw`.
- Process freeze is not covered by the lease (03 §3.6); `dataDurability: Required` is the mitigation.
