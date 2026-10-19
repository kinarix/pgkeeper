---
id: ADR-001
title: "ADR-001 — Go + kubebuilder/controller-runtime"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P0]
topics: [language, framework]
references: [00-overview, 08-testing-and-makefile]
related: "00-overview C8, 08 §2"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-001 — Go + kubebuilder/controller-runtime

## Context
The operator needs a mature controller framework, envtest, code generation and webhook support. WAL-G is written in Go, and most operator prior art (CNPG, Zalando, PGO) is Go.

## Decision
Go with kubebuilder (v4.16 scaffold) and controller-runtime (v0.25.x), Go 1.26 as of Sept 2026. Versions pinned per 08 §2.

## Alternatives rejected
- **Rust (kube-rs):** viable and a strong team skill, but the operator ecosystem (envtest, codegen, webhooks, testing tools) is thinner.

## Consequences
Revisit only if the operator must share code with an existing Rust/kube-rs platform.
