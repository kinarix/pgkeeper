# ADR-002 — Pods + PVCs managed directly, no StatefulSet

- Status: Accepted
- Date: 2026-10-15
- Related: 00-overview §4 (Division of authority), 03 §9–§10

## Context
StatefulSet ordered rollouts and ordinal identity fight primary-aware updates (update replicas first, switch over, then the old primary). Reused names also collide with replication slots named after instances.

## Decision
The operator manages Pods and PVCs directly, with monotonically increasing instance serials that are never reused.

## Alternatives rejected
- **StatefulSet:** ordinal-ordered rollouts and name reuse hazards with slots.

## Consequences
The operator owns rollout, scale-down selection and PVC lifecycle logic itself (03 §9–§11, invariant I5).
