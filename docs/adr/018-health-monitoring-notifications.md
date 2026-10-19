---
id: ADR-018
title: "ADR-018 — Pull-based health, IM-measured disk, shipped alert rules, optional HA webhook"
type: adr
status: accepted
decided: 2026-10-16
version: 0.2.0
updated: 2026-10-19
phases: [P5, P23]
topics: [health, disk, alerts, notifications]
references: [00-overview, 02-instance-manager, 03-ha, 05-access-control, 06-observability-dashboard, 07-reconciliation-and-tenancy, 11-ha-scenarios, ADR-003, ADR-016]
related: "00-overview C6; ADR-003 (IM stays PID 1 in the Postgres container); 02 §7–§8, 06 §2, 07 §1, 11 §22"
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "Add YAML metadata front matter"}
  - {version: 0.1.0, date: 2026-10-16, change: "Add design specs and ADRs"}
---

# ADR-018 — Pull-based health, IM-measured disk, shipped alert rules, optional HA webhook

## Context
- **Heartbeats.** The operator learns instance health by polling the IM. The specs never said so explicitly, or what happens when an instance stops answering.
- **Disk.** The only disk alert (`PVCAlmostFull`) used kubelet volume stats. Those aren't reported for hostPath-based local-path volumes (kind, k3d, many bare-metal setups), so it never fires there. WAL volumes and inodes weren't covered. A full `pg_wal` stops the primary, so this is an HA problem, not just a metrics one.
- **CPU/memory.** No alerts for memory pressure, OOM kills, restarts, CPU throttling or connection saturation. When the kernel OOM-kills a single Postgres backend, Postgres does crash recovery without the container restarting, so restart-based alerts miss it.
- **Notifications.** Failover alerts reached people only through a user-run Prometheus + Alertmanager.

C6 still applies: don't build a metrics or alerting platform.

## Decision
1. **Health is pulled, never pushed.**
   - The operator polls `GET /v1/status` every 5 s (jittered) over mTLS.
   - After 3 consecutive failed polls, the instance is `role: unknown` and not ready, with event `InstanceUnreachable`. This never triggers failover by itself: failover liveness comes from the quorum lease (03 §5.1, ADR-016).
2. **The IM measures what Kubernetes can't, on any storage.**
   - Every 15 s: `statfs` on the PGDATA and WAL mounts (bytes and inodes), and the `pg_wal` size.
   - cgroup v2 `memory.current`, `memory.max`, and the `oom_kill` count from `memory.events`.
   - Exposed in `/v1/status` and as metrics.
   - The operator maps volume usage to conditions `DiskPressure` and `WALDiskPressure` (reason `Warning`/`Critical`; thresholds `spec.monitoring.diskThresholds`, default 85/95 %; clears 5 points below). It emits events, including `BackendOOMKilled` when the OOM count rises.
   - No Prometheus needed for any of this.
3. **CPU, memory, restarts and saturation are alerted by shipped PrometheusRules**, built on IM metrics plus the standard kube-state-metrics and cAdvisor series. `PVCAlmostFull` is replaced by IM-based disk alerts.
4. **HA notifications via an optional webhook**, off by default.
   - Configured per cluster with `spec.notifications`, or operator-wide with `--notify-webhook-secret`.
   - Formats: `Generic` JSON or `Slack`.
   - A fixed set of HA and storage events (06 §2.5).
   - Delivered asynchronously, at least once, retried for up to 1 h, deduplicated.
   - The webhook URL lives in a Secret and is never logged.
5. **No automatic remediation in v1** (e.g. PVC auto-grow). That's a candidate later phase.

## Alternatives rejected
- **IM pushes heartbeats to the operator:** creates a second path to "instance is dead" that competes with the quorum lease, and makes the operator's view depend on IM-to-operator networking. The pull already gives the operator everything it needs within 5 s.
- **Built-in alert engine in the operator:** duplicates Prometheus/Alertmanager (C6).
- **Alertmanager only:** leaves clusters without Prometheus silent during failovers.
- **Kubelet volume stats for disk:** missing on local-path/hostPath volumes, which are the test and edge default.
- **Operator-wide webhook only:** one channel for every tenant's incidents breaks namespace tenancy (07 §4). Per-cluster config with an operator-wide fallback keeps both.

## Consequences
- New fields: `spec.monitoring.diskThresholds`, `spec.notifications`. New conditions: `DiskPressure`, `WALDiskPressure`. New status: `instances[].volumes`.
- The operator gains an outbound HTTP client and needs egress to webhook endpoints (05 §7).
- Webhook Secrets are user-referenced, unlabelled Secrets, so they hit the same label-restricted-cache problem as role and store Secrets (open review item, 07 §2 vs §4.3).
- The IM must handle cgroup v1 hosts gracefully: metrics absent, nothing fails.
