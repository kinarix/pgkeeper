---
id: ADR-020
title: "ADR-020 — `archive_mode = always` with dedup, so failover leaves no archive gap"
type: adr
status: accepted
decided: 2026-10-16
version: 0.2.0
updated: 2026-10-19
phases: [P18]
topics: [archiving]
references: [04-backup-restore, ADR-015]
related: "04 §4, §7; ADR-015 ledger row C2; invariant I6"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Resolve open spec review findings"}
---

# ADR-020 — `archive_mode = always` with dedup, so failover leaves no archive gap

## Context
With `archive_mode = on` only the primary archives. The PostgreSQL docs state that a promoted standby archives only the WAL it generates after promotion. Any segment the old primary had streamed but not yet archived when it died is missing from the archive. A point-in-time restore across that failover then hits a WAL gap (Phase 21 "restore across a failover timeline switch").

## Decision
- Every instance runs `archive_mode = always`. Replicas archive the segments they receive.
- `wal-archive` checks the store before uploading:
  - same segment with the same content (size + checksum) → success, no upload;
  - same name with different content → `ArchiveConflict` failure, never an overwrite (WAL-G `WALG_PREVENT_WAL_OVERWRITE=true`).
- **Exception:** the PITR-bootstrap instance runs with `on` until its first restart after promotion. With `always`, a server in archive recovery re-archives every segment it restores from the source store.

## Alternatives rejected
- **Keep `on` and document the gap:** PITR across failovers becomes unreliable, which is exactly when restores are needed.
- **One designated "archive standby":** fewer requests, but the gap reappears when that standby is not the one with the missing segment, or is down.

## Consequences
- One existence check (HEAD) per segment per replica. Uploads are rarely duplicated, because the primary usually wins.
- Store credentials are already mounted on every instance, so nothing new is exposed.
- The I6 ownership check (`cluster.json`) applies to replicas too (same cluster UID).
- Phase 18 acceptance gains a "primary killed before archiving" test (09).
