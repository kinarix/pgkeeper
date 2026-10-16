# ADR-013 — Debian-based official images only in v1

- Status: Accepted
- Date: 2026-10-15
- Related: 00-overview C3

## Context
The official image's `postgres` UID is 999 on Debian but 70 on Alpine.

## Decision
v1 supports only the Debian variants of the official image.

## Alternatives rejected
- **Debian and Alpine from the start:** doubles the UID/GID and test matrix.

## Consequences
Alpine is a later, explicit addition.
