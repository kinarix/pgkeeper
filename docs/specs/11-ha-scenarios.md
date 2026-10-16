# 11 — HA Scenarios: What Happens When…

Explanatory companion to **03-ha.md** and **ADR-016…021**. Those are normative; if this document disagrees with them, they win, and this document is the one to fix. Each scenario lists the setup, the step-by-step behaviour with timings, what clients see, the data-loss bound, and the test that proves it (`F#` = row in ADR-016's fault table).

Unless stated otherwise:
- Mode `spec.ha.quorum.mode: Peers` (the target design). Differences in `KubernetesLease` mode (the default until Phase 28) are called out.
- Default timings: `lease.duration` 15 s, `renewDeadline` 10 s, `retryPeriod` 2 s, `fenceTimeout` 3 s, `failoverDelay` 0, `voterRemovalDelay` 30 s, `maxFailoverLag` 64 MiB.
- Asynchronous replication (`synchronous.mode: Off`) unless stated.
- `t = 0` is the **send time of the primary's last renewal that still formed a sustain quorum**.

---

## 0. Background in one page

### 0.1 Who decides what
```mermaid
flowchart LR
    subgraph CP["Kubernetes control plane"]
        API["API server"]
        L["Lease orders-primary<br/>(Lease voter)"]
        API --- L
    end
    OP["pgkeeper operator<br/>(policy: who SHOULD be primary)"]
    subgraph Pods["Instance pods (IM = PID 1)"]
        A["orders-1<br/>IM + Postgres<br/>PRIMARY"]
        B["orders-2<br/>IM + Postgres<br/>replica"]
        C["orders-3<br/>IM + Postgres<br/>replica"]
    end
    OP -- "status.targetPrimary" --> API
    A -- "renew vote (CAS)" --> L
    A -- "renew vote /v1/vote" --> B
    A -- "renew vote /v1/vote" --> C
    B -. "WAL stream via orders-rw" .-> A
    C -. "WAL stream via orders-rw" .-> A
```
- **Safety** (at most one writable primary) comes from the quorum lease alone. Each instance manager enforces it locally.
- **Policy** (which instance should be primary) comes from the operator via `status.targetPrimary`. If the operator is down, failover is delayed, never unsafe.

### 0.2 The two quorums
| Action | Needs valid grants from |
|---|---|
| **Sustain** (keep writing) | the Lease **or** ≥ `Qs` instance voters |
| **Acquire** (promote) | the Lease **and** ≥ `Qa` instance voters |

`Qs = ⌊n/2⌋+1`, `Qa = n − Qs + 1`, and the holder's own vote counts. Every acquire quorum overlaps every sustain quorum, so two primaries are impossible.

| n | Qs / Qa | Primary keeps writing when… | Failover possible when… |
|---|---|---|---|
| 1 | Lease only | API server reachable | — |
| 2 | 2 / 1 | API reachable, **or** the replica is reachable | API + the candidate |
| 3 | 2 / 2 | API reachable, **or** ≥ 1 replica reachable | API + candidate + 1 |
| 5 | 3 / 3 | API reachable, **or** ≥ 2 replicas reachable | API + candidate + 2 |

### 0.3 The fencing clock
```mermaid
flowchart LR
    T0["t=0<br/>last renewal sent<br/>that formed a quorum"] --> T10["t=10 s<br/>grants stop counting<br/>(renewDeadline)<br/>→ immediate stop"]
    T10 --> T13["t≤13 s<br/>Postgres is down<br/>(SIGKILL after fenceTimeout)"]
    T13 --> T15["t≥15 s<br/>voters' grants expire<br/>(leaseDuration)<br/>→ someone else may acquire"]
```
The 2 s safety margin (15 − 10 − 3) is enforced by CEL. A new primary can't exist before the old one is down.

### 0.4 Scenario matrix
| § | Scenario | Writes during the event | Automatic failover | Acked-write loss (async) | Acked-write loss (`Required`) | Typical write outage |
|---|---|---|---|---|---|---|
| 1 | Planned switchover (Graceful) | paused | n/a (planned) | 0 | 0 | 1–5 s |
| 2 | Rolling update | paused once | n/a | 0 | 0 | 1–5 s |
| 3 | Node drain / primary pod deleted | paused once | n/a (switchover or handoff) | 0 | 0 | 1–5 s |
| 4 | Postmaster crash | errors during restart | only on crash loop / start timeout (configurable) | 0 (restart) / ≤ lag (escalation) | 0 | seconds; ≤ 30 s after escalation |
| 5 | Primary pod / node dies | none | yes | ≤ replication lag | 0 | ≤ 30 s |
| 6 | Primary fully isolated | errors after fence | yes | ≤ ~13 s of writes | 0 | ≤ 30 s |
| 7 | Primary cut off from API server only | continue | no (not needed) | 0 | 0 | 0 |
| 8 | Whole API server outage | continue (n ≥ 2) | impossible | 0 | 0 | 0 (n ≥ 2), until API returns (n = 1) |
| 9 | Replicas die (minimum availability) | continue | n/a | 0 | writes block | 0 |
| 10 | 2 instances split from each other | continue on primary | no | 0 | writes block | 0 |
| 11 | Sequential failures | continue / fail over | yes, to last survivor | ≤ lag | 0 | ≤ 30 s per failover |
| 12 | Simultaneous failures | none | no — human | ≤ lag | 0 | until human acts |
| 13 | Operator down / killed mid-failover | continue | delayed | unchanged | unchanged | + operator restart time |
| 14 | Process / VM freeze | stale writes possible | yes | stale writes possible | 0 | ≤ 30 s |
| 15 | No eligible candidate (lag) | none | waits | — | — | until replica catches up or human forces |
| 16 | Synchronous `Required`, quorum of standbys missing | blocked | waits | — | 0 | until standbys return |
| 17 | Pinning and primary override | per policy | per policy (switchback only after a human deletes the override) | as §5 | as §5 | as §5; switchback 1–5 s when acknowledged |
| 18 | Former primary rejoins | — | — | — | — | — |
| 19 | Node lost with local storage | — | — | — | — | — |
| 20 | Voter restarts mid-lease | continue | no | 0 | 0 | 0 |
| 21 | API server down **and** primary dies | none | impossible until API returns | ≤ lag | 0 | until API returns |
| 22 | Disk filling up (data or WAL) | continue until full, then stop | only via crash loop | ≤ lag | 0 | from "full" until failover or space freed |

---

## 1. Planned switchover (`PostgresSwitchover`, Graceful)

**Setup:** n = 3; `orders-1` primary; user creates a switchover to `orders-2`.

```mermaid
sequenceDiagram
    autonumber
    participant U as User / dashboard
    participant OP as Operator
    participant A as orders-1 (primary)
    participant B as orders-2 (target)
    participant V as Voters (Lease, orders-3)
    U->>OP: create PostgresSwitchover(to orders-2)
    OP->>OP: validate: Healthy, no other switchover, B lag < 16 MiB, pin OK
    OP->>A: POST /v1/checkpoint
    OP->>OP: status.targetPrimary = orders-2
    A->>A: pg_ctl stop -m fast (waits ≤ timeout/2)
    A->>A: read shutdown checkpoint LSN (pg_controldata)
    A->>V: release grants (release-reason=Switchover, shutdown-lsn)
    B->>B: wait until received/replayed LSN ≥ shutdown LSN
    B->>V: acquire (new term) — no expiry wait, grants were released
    V-->>B: grants (Lease + Qa)
    B->>B: pg_promote()
    OP->>OP: relabel pods → orders-rw points to orders-2
    A->>A: restart as replica, timeline check (pg_rewind should be a no-op)
```
- **Clients:** writes fail or queue from step 5 until `-rw` follows the new primary, typically 1–5 s. With a pooler (`pauseOnSwitchover`, Phase 27), queries queue instead of failing.
- **Data loss:** none. The target waits for the shutdown LSN.
- **Abort path:** if B doesn't reach the shutdown LSN within the timeout, the switchover fails, the operator resets `targetPrimary`, and A restarts and re-acquires.
- **Fast mode:** skips the drain and `CHECKPOINT` and waits at most `min(10 s, timeout/2)` for the fast stop, so zero loss and no rewind still hold. Only if the fast stop doesn't finish in time does the IM escalate to immediate; the switchover then completes as a failover to the target with `lossy: true` and the old primary goes through the rewind check (03 §7 step 3).
- **Proof:** Phase 9 — 10 switchovers under ledger load, 0 lost acked writes, p95 ≤ 5 s.

## 2. Rolling update (image digest, resources, restart-requiring parameters)

```mermaid
flowchart LR
    S["spec change<br/>(new spec-hash)"] --> R3["recreate orders-3<br/>wait Ready + streaming + lag ok"]
    R3 --> R2["recreate orders-2<br/>wait Ready + streaming + lag ok"]
    R2 --> M{"updateStrategy /<br/>updateMode"}
    M -- "Switchover" --> SW["Graceful switchover<br/>to most up-to-date updated replica (§1)"]
    SW --> R1["recreate old primary as replica"]
    M -- "Restart (required for n=1)" --> RS["restart primary in place<br/>outage = restart time"]
    M -- "Supervised" --> W["wait for user's PostgresSwitchover<br/>Progressing=WaitingForSwitchover"]
```
- Replicas go one at a time, highest serial first. The primary always goes last.
- **Clients:** one switchover-sized pause (1–5 s), or the restart time for `Restart`.
- **Proof:** Phase 13 — minor image bump under load, one switchover, ≤ 5 s, 0 lost writes.

## 3. Node drain of the primary's node, or primary pod deleted

**Drain** (`kubectl drain`): the drain cordons the node first; the primary PDB (minAvailable 1, selector `role=primary`) refuses the primary's eviction, so the operator reacts to the **node** instead (03 §9 step 5).

```mermaid
sequenceDiagram
    autonumber
    participant K as kubectl drain
    participant N as Node of orders-1
    participant OP as Operator
    participant A as orders-1 (primary)
    participant B as orders-2
    K->>N: cordon (unschedulable)
    K-xA: evict — refused by primary PDB
    OP->>OP: primary's node unschedulable → operator-initiated Graceful switchover
    OP->>B: switchover to orders-2 (§1)
    OP->>A: relabel orders-1 role=replica
    K->>A: evict retry → allowed (now under replicas PDB)
```
- **Clients:** one switchover pause (1–5 s), zero loss. No override is created (operator-initiated, ADR-017).

**Primary pod deleted or SIGTERM'd otherwise** (manual `kubectl delete pod`, node shutdown, eviction not pre-empted): **shutdown handoff** (03 §7.1, ADR-021). The IM fast-stops, records the shutdown LSN and releases with it; the operator promotes a replica that has received up to that LSN within `min(10 s, lease.duration)`. Result: zero lost commits, no rewind. If no replica gets there in time, a normal failover follows (§5).

- **Proof:** Phase 13 (drain → switchover precedes eviction), Phase 9 (delete primary pod under ledger load → 0 lost acked writes).

## 4. Postmaster crash on the primary (ADR-019)

**Setup:** n = 3; default `spec.ha.crashHandling` (`RestartInPlace`, 5 crashes in 5 min, backoff 1 s → 30 s, `startTimeout` 2 min).

```mermaid
flowchart TD
    C["postmaster crashes<br/>(or reinitialises after a backend crash, e.g. OOM)"] --> P{"crashHandling.policy"}
    P -- "FailoverImmediately" --> R1["release lease<br/>release-reason=Crash"]
    P -- "RestartInPlace" --> N{"crashes in window<br/>≥ maxRestarts?"}
    N -- "no" --> RS["keep lease, restart after backoff<br/>(deadline timer stays armed)"]
    RS --> T{"accepting connections<br/>within startTimeout?"}
    T -- "yes" --> OK["same primary<br/>no failover, no override, no data loss"]
    T -- "no" --> R2["release lease<br/>release-reason=RecoveryTimeout"]
    N -- "yes" --> R3["CrashLoop<br/>release lease (release-reason=CrashLoop)"]
    R1 --> FP{"failover possible?<br/>(n>1, candidate, quorum)"}
    R2 --> FP
    R3 --> FP
    FP -- "yes" --> FO["failover (§5), no expiry wait<br/>override created, webhook Critical"]
    FP -- "no (n=1, Strict pin on self, QuorumUnavailable…)" --> KR["keep lease, keep restarting at backoff.max<br/>condition CrashLoop"]
```
- **Clients:** a single crash means errors during crash recovery (typically seconds), then the same primary. On escalation: as §5 (≤ 30 s after release).
- **Data loss:** restart in place: none, since all committed WAL is on the primary's disk. Escalation: as §5.
- **Safety:** Postgres down accepts no writes. It is restarted as primary only while a sustain quorum is valid, and a lease loss during recovery fences as usual (03 §3.7).
- **Replicas:** always restart in place. A replica in `CrashLoop` is excluded from failover candidates.
- **Proof:** Phase 10 crash-handling acceptance.

## 5. Primary pod or node dies (unplanned failover)

**Setup:** n = 3; `orders-1` primary dies at t ≈ 0 (pod killed, node stopped).

```mermaid
sequenceDiagram
    autonumber
    participant A as orders-1 (primary)
    participant L as Lease voter
    participant B as orders-2
    participant C as orders-3
    participant OP as Operator
    Note over A: dies at t≈0 — no more renewals
    Note over L,C: grants to orders-1 expire at t≈15 s
    B-->>OP: /v1/status: grant to orders-1 expired
    C-->>OP: /v1/status: grant to orders-1 expired
    OP->>OP: Lease unchanged 15 s AND Qa(=2) expiry reports → primary failed
    OP->>OP: candidate selection (03 §5.3): max flush LSN, lag ≤ 64 MiB
    OP->>OP: status.targetPrimary = orders-2, phase FailingOver
    B->>L: acquire (term+1)
    B->>C: acquire (term+1)
    L-->>B: grant
    C-->>B: grant
    B->>B: replay received WAL (≤ 10 s), pg_promote()
    OP->>OP: relabel, slots on orders-2, -rw → orders-2
    OP->>OP: create PostgresPrimaryOverride(orders-2), FailoverUnacknowledged=True
    OP->>OP: notify webhook: FailoverStarted, FailoverCompleted (06 §2.5)
    C->>C: follow new timeline (recovery_target_timeline=latest)
```
- **Timeline:** detection at ~15–17 s, promotion shortly after (replay wait ≤ 10 s), then endpoint propagation. **Target ≤ 30 s.**
- **Data loss:** async: whatever had not reached the new primary when A died, bounded by the eligibility rule (lag ≤ `maxFailoverLag`). `Required`: none (§16).
- **Old primary:** stays down. If it comes back, it rejoins via §18 as a **replica** and stays one until a human deletes the override (§17).
- **Damping:** if the last failover was < 5 min ago, the operator waits `2 × failoverDelay` (min 30 s) before electing (event `FailoverDamped`).
- **Proof:** F6 (n = 3), F5 (n = 2), Phase 10 e2e-chaos.

## 6. Primary fully isolated (network partition from everything)

**Setup:** n = 3; at t ≈ 0 the primary's node loses all network: no API server, no peers. Clients on the same side of the partition (if any) can still reach it.

```mermaid
sequenceDiagram
    autonumber
    participant CL as Clients (same side as A)
    participant A as orders-1 (isolated)
    participant L as Lease voter
    participant B as orders-2
    participant C as orders-3
    CL->>A: writes keep succeeding (async: not replicated!)
    A-xL: renew fails
    A-xB: renew fails
    A-xC: renew fails
    Note over A: t=10 s: no valid sustain quorum → deadline timer fires
    A->>A: pg_ctl stop -m immediate (all sessions killed)
    Note over A: t≤13 s: Postgres down (SIGKILL fallback)
    CL-xA: connection errors → reconnect via orders-rw
    Note over L,C: t≥15 s: grants to orders-1 expire
    B->>L: acquire (term+1), with orders-3 → promote (as §5)
```
- **No split-brain:** A is down by t ≤ 13 s, and B can't acquire before t ≥ 15 s.
- **Data loss (async):** writes A acknowledged after it lost contact with the replicas were never streamed. That is up to ~13 s of writes, discarded when A rejoins via rewind (§18). With `Required` they block instead of being acknowledged, so none are lost.
- **Proof:** F7; Phase 8 acceptance (primary stops ≤ 13 s; ledger writer sees errors, not silent success).

## 7. Primary cut off from the API server only

**Setup:** n = 3. The primary's node can't reach the API server (e.g. a broken route), but the instances still reach each other.

```mermaid
sequenceDiagram
    autonumber
    participant A as orders-1 (primary)
    participant L as Lease voter
    participant B as orders-2
    participant C as orders-3
    participant OP as Operator
    A-xL: renew Lease fails
    A->>B: renew vote
    B-->>A: grant
    A->>C: renew vote
    C-->>A: grant
    Note over A: sustain quorum = {orders-1, orders-2, orders-3} ≥ Qs → keep writing
    OP->>OP: Lease stale 15 s, BUT orders-2/orders-3 report grants renewed
    Note over OP: no acquire quorum reports expiry → NOT failed, no failover
```
- **Clients:** unaffected.
- **While it lasts:** A can't see CR/ConfigMap updates (stale cache) and the operator can't relabel A's pod. Config changes wait.
- **`KubernetesLease` mode:** A fences at t ≤ 13 s, the operator fails over (§5), and clients see ≤ 30 s of outage. This is the ADR-015 C1 regression that `Peers` mode fixes.
- **Proof:** F2.

## 8. Whole API-server outage (control plane down, e.g. k3d server restart)

```mermaid
flowchart TB
    API["API server DOWN"]:::down
    subgraph n3["n=3 cluster"]
        A3["primary"] <--> B3["replica"]
        A3 <--> C3["replica"]
    end
    subgraph n2["n=2 cluster"]
        A2["primary"] <--> B2["replica"]
    end
    subgraph n1["n=1 cluster"]
        A1["primary"]
    end
    A3 -. "keeps writing (peers ≥ Qs)" .-> OK3["✓"]
    A2 -. "keeps writing (needs the replica)" .-> OK2["✓"]
    A1 -. "Lease only → fences at ≤13 s" .-> X1["✗"]
    classDef down stroke-dasharray: 5 5
```
- **n ≥ 2 in `Peers` mode:** no fence, writes continue (F1). Nothing can fail over during the outage (§21).
- **n = 1:** the instance path is disabled (03 §3), so the primary fences. A single instance can't prove it is the only one, e.g. if a re-attached RWO volume started a second pod.
- **n = 2 with the replica also down:** fences (F10 equivalent). That's a double fault.
- **`KubernetesLease` mode:** every primary fences.
- **During the outage:** no Services change, no CR edits, no failovers, no scaling. On recovery, the operator resyncs and nothing restarts.
- **Proof:** F1; Phase 10b on k3d (single-server restart causes no fence).

## 9. Replicas die — minimum availability

**Setup:** n = 3; both replicas die; the API server is fine.

```mermaid
sequenceDiagram
    autonumber
    participant A as orders-1 (primary)
    participant L as Lease voter
    participant B as orders-2 (dead)
    participant C as orders-3 (dead)
    participant OP as Operator
    A->>L: renew
    L-->>A: grant
    A-xB: renew fails
    A-xC: renew fails
    Note over A: sustain via Lease alone → keep writing
    OP->>OP: after voterRemovalDelay (30 s): remove orders-2, orders-3 (joint quorum, holder acks)
    Note over A,OP: n=1 → Lease-only; operator recreates/re-clones replicas when possible
```
- **Clients:** unaffected (async).
- **Durability:** while no replica runs, a primary failure means no failover and possibly a restore from backup. `Required`: writes **block** (the sync list never shrinks). `Preferred`: the list shrinks and `SynchronousDegraded` is set.
- **New replicas:** clone from the primary and are added back to the voter set (joint quorum).
- **Proof:** F4 (n = 3), F3 (n = 2), F7.

## 10. Two instances split from each other (n = 2)

```mermaid
flowchart LR
    API["API server + Lease"]
    A["orders-1 PRIMARY"]
    B["orders-2 replica"]
    A -- "renews Lease ✓" --> API
    B -- "can reach API ✓" --> API
    A x--x|"partition"| B
```
- A sustains on the Lease. B needs the Lease to acquire (Qa = 1, but the Lease is always required), and A holds it, so B can't promote.
- The operator sees the Lease being renewed, so no failover.
- **Clients:** unaffected. B's lag grows. If it exceeds `max_slot_wal_keep_size`, B needs a re-clone (`NeedsReclone`).
- **Proof:** F8.

## 11. Sequential failures — down to the last survivor

**Setup:** n = 3. orders-2 dies; 2 minutes later orders-1 (primary) dies.

```mermaid
sequenceDiagram
    autonumber
    participant A as orders-1 (primary)
    participant B as orders-2
    participant C as orders-3
    participant OP as Operator
    Note over B: dies
    A->>C: renew (sustain: Lease + orders-1 + orders-3)
    OP->>OP: orders-2 failed > 30 s → remove from voter set (voterEpoch+1)
    A-->>OP: holder renewed under new epoch with quorums of old AND new set → change complete
    Note over A,C: now n=2 {orders-1, orders-3}: Qs=2, Qa=1
    Note over A: dies
    OP->>OP: Lease stale + Qa(=1) report from orders-3 → failed
    C->>C: acquire with Lease + itself → promote
```
- Each failure that's noticed before the next one shrinks the voter set, so failover keeps working until one instance is left.
- After that, the cluster is Lease-only (n = 1). Losing the last instance means restoring from backup.
- **Proof:** F12, F15.

## 12. Simultaneous failures (before the voter set can shrink)

**Setup:** n = 3. orders-1 (primary) and orders-2 die at the same moment, e.g. a zone outage.
- orders-3 needs the Lease plus `Qa = 2` instance votes. Only its own vote is available, so it can't promote.
- The operator sets `PrimaryAvailable=False reason=QuorumUnavailable`. The cluster stays read-only (orders-3 keeps serving `-ro`).
- **Why it waits:** from orders-3's view, "orders-1 and orders-2 are dead" looks identical to "they're cut off from me and the API server and still serving writes together" (they would be sustaining on each other).
- **Human path:** confirm they're really down (e.g. the nodes are gone in the cloud console), then create a `PostgresSwitchover` with `mode: Fast` and `pgkeeper.in/force-promote: orders-3`. The operator removes the dead voters without acknowledgement, and orders-3 promotes with Lease + itself.
- **Data loss:** ≤ lag of orders-3 (async). With `Required` and `ANY 1`, orders-3 may lack commits only orders-2 had acknowledged; the forced promotion makes that explicit.
- **Proof:** F13.

## 13. Operator down, or killed mid-failover

- **Primaries:** unaffected. They renew with voters directly; the operator isn't a voter.
- **Failover:** delayed until a leader operator replica is back (leader election ≤ 15 s, plus any restart). Failover is never unsafe, because the lease rules don't depend on the operator.
- **Mid-failover kill:** `targetPrimary` and `phase: FailingOver` are persisted in status. The new leader resumes: the candidate either already holds an acquire quorum and promotes, or keeps trying.
- **Proof:** Phase 10 e2e-chaos ("kill operator during failover"); Phase 26 (kill leader, reconcile resumes ≤ 20 s).

## 14. Process or VM freeze (SIGSTOP, VM pause, stop-the-world)

```mermaid
sequenceDiagram
    autonumber
    participant CL as Clients
    participant A as orders-1 (frozen pod)
    participant B as orders-2
    Note over A: whole pod frozen (IM + Postgres) for > 15 s
    Note over B: grants expire → orders-2 promoted (§5)
    Note over A: resumes
    CL->>A: in-flight / queued statements may commit on the OLD primary
    A->>A: IM deadline timer fires on resume → immediate stop
```
- The lease can't stop a frozen process from finishing work in the moment between resuming and the IM noticing. This is the documented limit (03 §3.6).
- **Only complete fix:** `synchronous.dataDurability: Required`. The old primary's commits wait for standby acknowledgements that never come, because the standbys now follow the new primary.
- **Freeze of the postmaster only (IM still running):** the IM sees Postgres unhealthy, then fences; SIGKILL works on stopped processes.
- **Proof:** F16; Phase 11 (`Required` → 0 lost acked writes, 0 stolen ids under SIGSTOP).

## 15. No eligible candidate (all replicas too far behind)

- Candidates whose lag vs the last known primary LSN exceeds `maxFailoverLag` (64 MiB) are excluded (03 §5.3).
- If all are excluded: no failover, condition `NoEligibleCandidate`. The operator waits for a replica to catch up (if the primary is gone, it can only catch up from the WAL archive), or for a human to force it.
- **Force:** `PostgresSwitchover mode: Fast` + `pgkeeper.in/force-promote: <instance>`, accepting the loss of everything beyond that replica's LSN.

## 16. Synchronous replication `Required`

**Setup:** n = 3, `mode: Quorum`, `number: 1` → `synchronous_standby_names = 'ANY 1 (orders-2, orders-3)'`.
- **Normal:** each commit waits for 1 of the 2 standbys. No acknowledged write exists on the primary alone.
- **Failover:** the operator picks the highest flush LSN, but only if at least `n−1 − k + 1 = 2` replicas reported. Otherwise the replica holding the acknowledged write might be the unreachable one, so it waits with `QuorumUnavailable` (03 §5.3 step 4). Data loss is 0.
- **Both standbys down:** writes block (durability over availability). `Preferred` would instead shrink the list and set `SynchronousDegraded`.
- **Scope of the guarantee (I3):** commits made with `synchronous_commit = on` or `remote_apply`. Sessions, roles or databases that lower it to `local`/`off` are not covered; the IM reports role/database overrides as condition `SynchronousCommitOverridden` (03 §6).

## 17. Pinning and the primary override (ADR-017)

Who should be primary: **`PostgresPrimaryOverride` > `spec.primary.pin` > best candidate**. The operator creates/updates the override after every automatic failover and every human-requested switchover. Only a human deletes it.

```mermaid
sequenceDiagram
    autonumber
    participant H as Human / dashboard
    participant OP as Operator
    participant P as orders-1 (pinned, Preferred)
    participant B as orders-2
    Note over P: primary, dies
    OP->>B: failover (§5)
    OP->>OP: create override(orders-2), FailoverUnacknowledged=True
    Note over P: recovers, rejoins as replica (§18)
    Note over OP: override beats pin → orders-2 stays primary (no automatic switchback)
    H->>OP: delete override ("Acknowledge failover")
    OP->>OP: wait until orders-1 healthy and lag < 16 MiB (SwitchbackWaiting)
    OP->>P: Graceful switchover back (§1), no new override
```

| Policy | Primary fails | Failed instance recovers | Human deletes the override |
|---|---|---|---|
| unset | failover (§5); override created | stays a replica | nothing moves; condition cleared |
| `Preferred` | failover elsewhere; override created | stays a replica | Graceful switchover back to the pinned instance |
| `Strict` | **no failover**; read-only; `StrictPinWaiting`; no override | becomes primary again | — (never created) |

- Human switchover to a non-pinned target: `Rejected` under Strict. Allowed under Preferred, and it creates/updates the override, so the pin does not pull it back.
- Operator-initiated switchovers (rolling update, eviction) update an existing override but never create one.
- Override older than 24 h → alert `FailoverUnacknowledged` (info).
- In `Peers` mode, `Strict` still needs the pinned instance to obtain an acquire quorum.

## 18. Former primary rejoins

```mermaid
flowchart TD
    S["IM starts with existing PGDATA,<br/>someone else holds the lease"] --> T["read local timeline + checkpoint<br/>(pg_controldata)"]
    T --> H["fetch new primary's timeline history"]
    H --> D{"diverged after<br/>fork point?"}
    D -- "no" --> R["start in recovery, stream"]
    D -- "yes" --> W["pg_rewind --source-server=orders-rw"]
    W -- "ok" --> R
    W -- "fails (missing WAL…)" --> N["NeedsReclone → operator replaces PVC<br/>(never the primary's, I5)"]
```
- After §1 (switchover): no divergence, so the rewind is a no-op.
- After §5/§6: divergence is likely (async writes after the fork are discarded).
- pg_rewind connects as the dedicated `pgkeeper_rewind` role (cert auth, read-only file-access grants; 05 §1.4, §4). If the old primary crashed or was fenced, pg_rewind first runs crash recovery on it.

## 19. Node lost with node-local storage (kind/k3d local-path, bare metal)

- Pods with local PVs can't move. After `nodeLossTimeout` (10 min):
  - **replica:** delete PVC + pod, recreate on another node, re-clone. In `Peers` mode, its voter was already removed after `voterRemovalDelay`, and the new instance is added back.
  - **former primary:** failover already happened (§5); then treated like a replica.
  - **only instance:** never auto-deleted (I5). `InstanceStranded` is raised.

## 20. A voter restarts mid-lease

- An instance voter persists (candidate, term, voterEpoch) before answering.
- After a restart it treats that grant as freshly given and refuses other candidates for a full `leaseDuration`. The holder simply continues renewing.
- **Proof:** F14.

## 21. API server down **and** the primary dies

- Survivors can't acquire, because every acquire quorum needs the Lease. The operator can't set `targetPrimary`, and `-rw` can't be re-pointed anyway.
- Writes are unavailable until the API server returns. Then it's §5 as normal.
- This is the deliberate trade-off for never fencing a healthy primary during a control-plane outage (§7, §8).
- **Proof:** F11.

## 22. Disk filling up (data or WAL volume)

The most common cause is a stuck WAL archive: segments can't be uploaded, so `pg_wal` keeps growing (04 §4). Other causes are data growth or a replication slot holding WAL for a dead replica (capped by `maxSlotWALKeepSize`).

```mermaid
flowchart TD
    S["archive failing / data growth / slot retention"] --> G["pg_wal or data grows"]
    G --> W["≥ 85 %: DiskPressure or WALDiskPressure = Warning<br/>event + webhook (Warning) + alert"]
    W --> C["≥ 95 %: condition = Critical<br/>event + webhook (Critical) + alert"]
    C --> F{"volume full?"}
    F -- "no, space freed or volume expanded" --> OK["condition clears 5 points below threshold"]
    F -- "yes" --> P["Postgres PANIC (cannot write WAL)"]
    P --> L["IM restarts postmaster with backoff,<br/>still fails: no space"]
    L --> CL["maxRestarts crashes in window (default 5 in 5 min):<br/>CrashLoop, lease released (release-reason=CrashLoop) — §4"]
    CL --> FO["failover to a replica (§5)<br/>override created, webhook Critical"]
    FO --> Q["new primary archives to the same store:<br/>if the store is the cause, it fills up next"]
```
- **Where it's measured:** the IM measures `statfs` itself every 15 s, so this works on local-path/hostPath volumes, where kubelet volume stats are missing (ADR-018).
- **Clients:** unaffected until the volume is full; then errors until failover (≤ 30 s after the crash loop is declared) or until space is freed.
- **Data loss:** async: ≤ replication lag at the PANIC. With `Required`: 0.
- **What to do at Warning:** fix the archive (`ContinuousArchiving=False` points at it), or increase `storage.size` / `walStorage.size` (allowed when the StorageClass supports expansion). Failover doesn't fix a store outage: the new primary inherits it.
- **Not in v1:** automatic PVC growth (ADR-018, possible later phase).
- **Proof:** Phase 5 (condition on fill/free), Phase 18 (wrong store credentials → WAL accumulates → `ContinuousArchiving=False`), Phase 23 (alerts and webhook).

---

## Appendix A — Mode comparison
| Scenario | `KubernetesLease` | `Peers` |
|---|---|---|
| §7 Primary cut off from API only | fence + failover, ≤ 30 s outage | no impact |
| §8 API server outage | every primary fences | n ≥ 2: no impact |
| §9 All replicas dead, API fine | keep writing | keep writing |
| §10 2-instance split | keep writing | keep writing |
| §12 Simultaneous loss of primary + replica (n=3) | automatic failover to the survivor | human-confirmed forced promotion |
| Extra moving parts | none | peer mTLS, `/v1/vote`, voter-set changes |

## Appendix B — Previously open issues (all resolved)
| Where | Issue | Resolution |
|---|---|---|
| §1 | Fast switchover couldn't guarantee zero loss | Fast uses a fast stop too; immediate only as a flagged escalation (03 §7) |
| §3 | Primary eviction never signalled under the PDB | Operator reacts to the node being cordoned (03 §9); SIGTERM handoff otherwise (ADR-021) |
| §4 | Restart vs step down on a postmaster crash | ADR-019 |
| §5, §6 | Archive gap after failover | ADR-020 |
| §16 | `synchronous_commit` overrides vs I3 | I3 scoped; `SynchronousCommitOverridden` condition (03 §1, §6) |
| §18 | `pg_rewind` connection/privileges | `pgkeeper_rewind` role (05 §1.4) |
