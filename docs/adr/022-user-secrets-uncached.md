# ADR-022 — User-referenced Secrets: metadata-only watch + uncached reads

- Status: Accepted
- Date: 2026-10-16
- Related: 07 §2, §4.3; 05 §6.1

## Context
The operator caches Secrets only with label `app.kubernetes.io/managed-by=pgkeeper`, to keep memory bounded: operators that cache every Secret have crash-looped in large, Helm-heavy clusters. Some Secrets belong to the user and carry no such label:
- role passwords (`passwordSecretRef`)
- backup store credentials
- notification webhook URLs
- `UserProvided` TLS

The operator needs both to read these Secrets and to notice when they change, for example to rotate a password within 60 s (Phase 15).

## Decision
- **Watch Secrets metadata-only** (`PartialObjectMetadata`; no data, a few hundred bytes each) in the watched namespaces.
- **Map changes to the CRs that reference them** via field indexers on the referencing fields.
- **Read Secret data with an uncached GET** (APIReader), only while reconciling a referencing CR.
- **Never label or annotate user Secrets.** GitOps tools would fight it, and it is a write to objects the user owns.

## Alternatives rejected
- **Full cache of all Secrets:** the memory blow-up the label restriction exists to prevent.
- **Require users to label their Secrets:** easy to forget; fails silently.
- **Operator labels referenced Secrets:** mutates user objects; GitOps drift.
- **Polling Secrets on resync:** password rotation would take up to `--sync-period` (10 min).

## Consequences
- One extra GET per referenced Secret per reconcile of a referencing CR. Bounded by reconcile rate; covered by the Phase 26 load test.
- The metadata informer covers all Secrets in watched namespaces, which is small even for thousands of Secrets. Its memory counts toward the Phase 26 RSS budget (< 512 MiB).
