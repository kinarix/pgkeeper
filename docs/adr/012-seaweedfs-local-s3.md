---
id: ADR-012
title: "ADR-012 — Local S3 for tests: SeaweedFS"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P0, P18]
topics: [testing, s3]
references: [04-backup-restore, 08-testing-and-makefile]
related: "04 §10, 08 §4"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-012 — Local S3 for tests: SeaweedFS

## Context
MinIO archived its community repo in April 2026 and stopped publishing images in Oct 2025.

## Decision
SeaweedFS (`weed server -s3`) is the local S3 stand-in, digest-pinned.

## Alternatives rejected
- **MinIO:** no maintained community images. **Garage** remains the fallback.

## Consequences
S3-compatibility quirks found in tests must be checked against real S3 before being treated as WAL-G bugs.
