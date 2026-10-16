# ADR-017 — Failover creates a PostgresPrimaryOverride; only a human deletes it

- Status: Accepted
- Date: 2026-10-16
- Amends: ADR-007 (adds an operator-written override; pin and switchover stay as decided)
- Related: 00-overview C5, 01 §1, §2, §12, 03 §5.4, §7, §8, 11 §5, §17

## Context
The operator decides who *should* be primary: the pin (`spec.primary.pin`), else the best candidate (03 §5.3). Under a `Preferred` pin, today's spec switches back to the pinned instance automatically after `switchbackDelay`. That has three problems:
- **Failback is a second outage** (a switchover costs 1–5 s of writes), taken at a time no human chose.
- **Flapping.** A flaky pinned instance can pull the primary back and forth.
- **Unacknowledged incidents.** Nothing records that the cluster is running on a primary nobody picked, or requires anyone to look at it.

C5/ADR-007 rejected a separate pin CRD because two objects deciding who is primary, with no precedence, is a bug factory. An override is acceptable only if precedence and ownership are unambiguous.

## Decision
1. **Every automatic failover** makes the operator create, or update, the cluster's `PostgresPrimaryOverride` (`<cluster>-primary-override`, one per cluster). Its `spec.instance` is the instance just promoted. This applies with or without a pin.
2. **Precedence** for `status.targetPrimary`: override > pin > best candidate (03 §5.3). The operator remains the only writer of `status.targetPrimary`. The override is an input, like the pin.
3. **Ownership.** Only the operator creates or updates an override, and it **never deletes** one. A human deletes it, which is the acknowledgement. RBAC: `delete` is in `pgkeeper-operator-user`; the dashboard (v2) offers "Acknowledge failover".
4. **Later events while an override exists:**
   - another automatic failover → the operator updates `spec.instance` and appends to `status.history`;
   - a **human-requested** `PostgresSwitchover` (any target, including the pinned instance) → on completion the operator creates or updates the override to the switchover's target, so a pin never silently pulls the primary back;
   - an **operator-initiated** switchover (rolling update or eviction, 03 §9) → updates an *existing* override to the new primary, but never creates one, so routine maintenance leaves nothing to acknowledge. The switchback after deletion and the initial move to a newly set pin create nothing either.
5. **On deletion**, the base policy applies again:
   - `Preferred` pin, pinned instance not primary → automatic **Graceful switchover** (03 §7) once the pinned instance is healthy and lag < 16 MiB. Until then: condition `Progressing reason=SwitchbackWaiting`.
   - no pin, or the pin already is the primary → nothing moves.
6. **`Strict` pin is unchanged.** It never fails over, so it never creates an override. A human switchover to a non-pinned target is still `Rejected`.
7. **Visibility.** While an override exists, the cluster carries condition `FailoverUnacknowledged=True`, with an info alert after 24 h (06 §2.3).
8. `spec.primary.pin.switchbackDelay` is **removed**; switchback is always human-gated. Flap damping for *failovers* (03 §5.2) is unchanged.

## Alternatives rejected
- **Automatic switchback after `switchbackDelay`** (previous spec): failback outage at an unchosen time; flapping.
- **A field on `PostgresCluster` instead of a CRD** (e.g. `status.override`): status can't be deleted by a human as an acknowledgement, and writing to `spec` from the operator fights GitOps. A separate object gives its own RBAC, events and audit trail.
- **Override only when a pin exists:** unpinned failovers would go unacknowledged.
- **Operator deletes the override when a switchover to the pinned instance completes:** breaks the "only a human deletes" rule. Instead, the override is updated to the pinned instance and the human deletes it, which is then a no-op.

## Consequences
- New kind `PostgresPrimaryOverride` (short name `pgpo`), owned by the cluster (garbage-collected with it).
- One more input to `targetPrimary`. Precedence must be implemented in a single pure function in `internal/ha` and unit/property tested.
- Clusters can run on a non-preferred primary indefinitely if nobody acknowledges. `FailoverUnacknowledged` and the 24 h alert exist to prevent that.
- GitOps: the override isn't in Git. Tools only prune what they track, so it isn't pruned, but any blanket `kubectl delete` of pgkeeper CRs in a namespace triggers a switchback.
