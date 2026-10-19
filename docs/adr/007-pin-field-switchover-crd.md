---
id: ADR-007
title: "ADR-007 — Pin = spec field; Switchover = CRD"
type: adr
status: accepted
decided: 2026-10-15
amended_by: "ADR-017 (operator-written PostgresPrimaryOverride after failover; human-gated switchback)"
version: 0.2.0
updated: 2026-10-19
phases: [P9, P12]
topics: [pinning, switchover]
references: [00-overview, 01-api, 03-ha]
related: "00-overview C5, 01 §1–§2, 03 §7–§8"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-007 — Pin = spec field; Switchover = CRD

## Context
The requirement asked to "pin a primary via another CRD". A separate pin CRD and the cluster CRD would both decide who is primary, with no defined precedence and ordering races.

## Decision
- Pinning (standing preference) is `PostgresCluster.spec.primary.pin` (`Preferred` or `Strict`).
- Switchover (one-shot action) is the `PostgresSwitchover` CRD, with its own audit trail, status and RBAC.

## Alternatives rejected
- **Separate pin CRD:** two writers for one fact.

## Consequences
If only some users may pin, enforce it with a `ValidatingAdmissionPolicy` on `spec.primary`, not a second CRD.
