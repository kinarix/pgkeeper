---
id: ADR-011
title: "ADR-011 — Dashboard live logs via K8s pod-log API (follow) in v1"
type: adr
status: accepted
decided: 2026-10-15
version: 0.2.0
updated: 2026-10-19
phases: [P24]
topics: [dashboard, logs]
references: [06-observability-dashboard]
related: "06 §4–§5"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-011 — Dashboard live logs via K8s pod-log API (follow) in v1

## Context
The dashboard must live-tail Postgres and access logs (R9) without storing them.

## Decision
Use `GET pods/{name}/log?follow=true` through the impersonated user.

## Alternatives rejected
- **A direct IM log-stream endpoint:** kept as a later optimization.

## Consequences
Reuses RBAC (`pods/log`); no extra IM endpoint in v1.
