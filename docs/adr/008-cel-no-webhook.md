---
id: ADR-008
title: "ADR-008 — CRD validation via OpenAPI + CEL, no admission webhook"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P1]
topics: [crd, cel, webhook]
references: [01-api]
related: "01 §0, §11"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-008 — CRD validation via OpenAPI + CEL, no admission webhook

## Context
Admission webhooks need certificate plumbing and complicate early phases and local testing.

## Decision
Validate with OpenAPI schemas and CEL (`x-kubernetes-validations`). No admission webhook until a conversion webhook is needed (`v1beta1`, after Phase 28).

## Alternatives rejected
- **Validating/mutating webhook from Phase 1.**

## Consequences
Rules that need other objects (CEL can't see them) are enforced at reconcile time with conditions such as `UnsupportedChange`.
