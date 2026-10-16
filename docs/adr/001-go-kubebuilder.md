# ADR-001 — Go + kubebuilder/controller-runtime

- Status: Accepted
- Date: 2026-10-15
- Related: 00-overview C8, 08 §2

## Context
The operator needs a mature controller framework, envtest, code generation and webhook support. WAL-G is written in Go, and most operator prior art (CNPG, Zalando, PGO) is Go.

## Decision
Go with kubebuilder (v4.16 scaffold) and controller-runtime (v0.25.x), Go 1.26 as of Sept 2026. Versions pinned per 08 §2.

## Alternatives rejected
- **Rust (kube-rs):** viable and a strong team skill, but the operator ecosystem (envtest, codegen, webhooks, testing tools) is thinner.

## Consequences
Revisit only if the operator must share code with an existing Rust/kube-rs platform.
