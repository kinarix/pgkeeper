---
id: ADR-003
title: "ADR-003 — Instance manager as PID 1 inside the official image"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P0, P2, P3]
topics: [instance-manager, image-volume]
references: [00-overview, 02-instance-manager]
related: "00-overview C3, 02 §1–§2"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-003 — Instance manager as PID 1 inside the official image

## Context
R5 requires unmodified official `postgres` images, which contain only PostgreSQL. HA, backup and log streaming need an agent and WAL-G.

## Decision
Run a static `pgkeeper-instance` binary as PID 1 in the Postgres container, injected together with a static `wal-g` via a Kubernetes image volume, with an init-container copy fallback for clusters without image volumes.

## Alternatives rejected
- **Patroni:** needs Python in the image (violates R5); Spilo is a custom image.
- **IM as a sidecar:** it must supervise the postmaster process (signals, PID-1 death semantics).

## Consequences
- If the IM dies, the kernel kills Postgres with it — no unsupervised postmaster.
- Extensions not in the image need PG18+ `extension_control_path` + image volumes, or a custom image.
