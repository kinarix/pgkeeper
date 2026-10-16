# ADR-010 — Dashboard authorizes via K8s impersonation

- Status: Accepted
- Date: 2026-10-15
- Related: 05 §6.3, 06 §4

## Context
The dashboard reads CRs and logs and creates CRs on a user's behalf.

## Decision
The dashboard calls the Kubernetes API impersonating the OIDC user and groups; the user's own RBAC decides.

## Alternatives rejected
- **A dashboard-side authorization model:** a second model to keep in sync with RBAC.

## Consequences
The dashboard ServiceAccount needs `impersonate`; list/watch can't use shared informers per user (06 §5 uses short per-user caches).
