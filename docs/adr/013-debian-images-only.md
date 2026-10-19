---
id: ADR-013
title: "ADR-013 — Debian-based official images only in v1"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P0, P2]
topics: [images]
references: [00-overview]
related: "00-overview C3"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-013 — Debian-based official images only in v1

## Context
The official image's `postgres` UID is 999 on Debian but 70 on Alpine.

## Decision
v1 supports only the Debian variants of the official image.

## Alternatives rejected
- **Debian and Alpine from the start:** doubles the UID/GID and test matrix.

## Consequences
Alpine is a later, explicit addition.
