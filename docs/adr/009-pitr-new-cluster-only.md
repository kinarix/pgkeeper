---
id: ADR-009
title: "ADR-009 — PITR only into a new cluster; archive path collision is rejected"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P18, P21]
topics: [pitr, archiving]
references: [00-overview, 01-api, 04-backup-restore]
related: "00-overview C7, 01 §9, 04 §2, §7, invariant I6"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-009 — PITR only into a new cluster; archive path collision is rejected

## Context
In-place "rewind the production DB" is a footgun, and two timelines archiving to one path corrupt the archive.

## Decision
PITR always bootstraps a **new** cluster from a backup store. The new cluster must archive to a different path than its source (CEL + runtime ownership check).

## Alternatives rejected
- **In-place restore.**

## Consequences
Restoring requires capacity for a second cluster; cut-over is the user's responsibility.
