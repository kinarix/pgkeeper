---
id: ADR-002
title: "ADR-002 — Pods + PVCs managed directly, no StatefulSet"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P3, P6]
topics: [pods, pvcs, statefulset]
references: [00-overview, 03-ha]
related: "00-overview §4 (Division of authority), 03 §9–§10"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-002 — Pods + PVCs managed directly, no StatefulSet

## Context
StatefulSet ordered rollouts and ordinal identity fight primary-aware updates (update replicas first, switch over, then the old primary). Reused names also collide with replication slots named after instances.

## Decision
The operator manages Pods and PVCs directly, with monotonically increasing instance serials that are never reused.

## Alternatives rejected
- **StatefulSet:** ordinal-ordered rollouts and name reuse hazards with slots.

## Consequences
The operator owns rollout, scale-down selection and PVC lifecycle logic itself (03 §9–§11, invariant I5).
