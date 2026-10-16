# ADR-011 — Dashboard live logs via K8s pod-log API (follow) in v1

- Status: Accepted
- Date: 2026-10-15
- Related: 06 §4–§5

## Context
The dashboard must live-tail Postgres and access logs (R9) without storing them.

## Decision
Use `GET pods/{name}/log?follow=true` through the impersonated user.

## Alternatives rejected
- **A direct IM log-stream endpoint:** kept as a later optimization.

## Consequences
Reuses RBAC (`pods/log`); no extra IM endpoint in v1.
