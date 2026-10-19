---
id: ADR-010
title: "ADR-010 — Dashboard authorizes via K8s impersonation"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P24, P25]
topics: [dashboard, impersonation]
references: [05-access-control, 06-observability-dashboard]
related: "05 §6.3, 06 §4"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-010 — Dashboard authorizes via K8s impersonation

## Context
The dashboard reads CRs and logs and creates CRs on a user's behalf.

## Decision
The dashboard calls the Kubernetes API impersonating the OIDC user and groups; the user's own RBAC decides.

## Alternatives rejected
- **A dashboard-side authorization model:** a second model to keep in sync with RBAC.

## Consequences
The dashboard ServiceAccount needs `impersonate`; list/watch can't use shared informers per user (06 §5 uses short per-user caches).
