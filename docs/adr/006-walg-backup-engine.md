---
id: ADR-006
title: "ADR-006 — WAL-G as v1 backup engine, behind an interface that supports sidecar engines"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P0, P18, P19, P20, P21]
topics: [backup, wal-g]
references: [02-instance-manager, 04-backup-restore, ADR-003]
related: "02 §2, 04 §3, §8"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-006 — WAL-G as v1 backup engine, behind an interface that supports sidecar engines

## Context
The backup engine must run inside the unmodified official image (ADR-003), so it must be injectable as a static binary.

## Decision
WAL-G is the v1 engine, built `CGO_ENABLED=0` from a pinned commit into the tools image (compression limited to lz4/zstd/lzma). It sits behind a `BackupEngine` interface that also supports **sidecar engines**: same pod, shared PGDATA volume, IM forwards `archive_command`/backup calls over localhost gRPC (the pattern CNPG uses for its barman-cloud plugin).

## Alternatives rejected
- **Barman/barman-cloud:** backup-only tools and Python-based — cannot be injected into the official image. Possible later as a sidecar engine.
- **pgBackRest:** C binary with shared-lib deps. Possible later as a sidecar engine.

## Consequences
WAL-G releases are irregular (v3.0.8, Jan 2026; important fixes merged but unreleased), so we build from a pinned commit rather than a release.
