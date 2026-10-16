# ADR-012 — Local S3 for tests: SeaweedFS

- Status: Accepted
- Date: 2026-10-15
- Related: 04 §10, 08 §4

## Context
MinIO archived its community repo in April 2026 and stopped publishing images in Oct 2025.

## Decision
SeaweedFS (`weed server -s3`) is the local S3 stand-in, digest-pinned.

## Alternatives rejected
- **MinIO:** no maintained community images. **Garage** remains the fallback.

## Consequences
S3-compatibility quirks found in tests must be checked against real S3 before being treated as WAL-G bugs.
