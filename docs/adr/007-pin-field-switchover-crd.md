# ADR-007 — Pin = spec field; Switchover = CRD

- Status: Accepted
- Amended by: ADR-017 (operator-written PostgresPrimaryOverride after failover; human-gated switchback)
- Date: 2026-10-15
- Related: 00-overview C5, 01 §1–§2, 03 §7–§8

## Context
The requirement asked to "pin a primary via another CRD". A separate pin CRD and the cluster CRD would both decide who is primary, with no defined precedence and ordering races.

## Decision
- Pinning (standing preference) is `PostgresCluster.spec.primary.pin` (`Preferred` or `Strict`).
- Switchover (one-shot action) is the `PostgresSwitchover` CRD, with its own audit trail, status and RBAC.

## Alternatives rejected
- **Separate pin CRD:** two writers for one fact.

## Consequences
If only some users may pin, enforce it with a `ValidatingAdmissionPolicy` on `spec.primary`, not a second CRD.
