# ADR-008 — CRD validation via OpenAPI + CEL, no admission webhook

- Status: Accepted
- Date: 2026-10-15
- Related: 01 §0, §11

## Context
Admission webhooks need certificate plumbing and complicate early phases and local testing.

## Decision
Validate with OpenAPI schemas and CEL (`x-kubernetes-validations`). No admission webhook until a conversion webhook is needed (`v1beta1`, after Phase 28).

## Alternatives rejected
- **Validating/mutating webhook from Phase 1.**

## Consequences
Rules that need other objects (CEL can't see them) are enforced at reconcile time with conditions such as `UnsupportedChange`.
