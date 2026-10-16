# ADR-016 — Quorum lease: the primary survives on the K8s Lease *or* its peers; promotion needs both

- Status: Accepted
- Date: 2026-10-16
- Supersedes: ADR-004
- Related: 03 §1, §3, §5, §10–§11; ADR-005 (unchanged); ADR-015 ledger rows C1, A8

## Context
ADR-004 made a single Kubernetes `Lease` the only split-brain guard. It is safe, but it ties every primary's availability to the API server: any API-server outage, including restarting a single-server k3d control plane, fences every primary in the fleet within `renewDeadline + fenceTimeout` (ADR-015 row C1).

Requirements for the replacement:
1. **Minimum availability.** A healthy primary keeps accepting writes with as little support as safely possible: alone while the API server is reachable, and with its peers while the API server is not.
2. **No split-brain** (invariant I1) in any partition, including one-sided ones.
3. **One safety mechanism** with one timer (ADR-004's principle, and the lesson of the Coroot study).

The lease needs one agreed order of updates. The API server (etcd) is one way to get that, not the only one. Kafka's KRaft shows the alternative: a quorum with monotonically increasing epochs decides leadership, and leaders hold time-bounded sessions with it. Unlike Kafka, though, Postgres clients connect straight to the primary and nothing rejects a stale leader for us, so the instance manager must still fence itself.

## Decision
The primary lease is a **quorum lease**. Its voters are the `<cluster>-primary` K8s Lease plus the cluster's instance managers. Staying primary and becoming primary use **different quorums**:

| Action | Requires valid grants from |
|---|---|
| **Sustain** (keep accepting writes) | the K8s Lease, **or** at least `Qs` instance voters |
| **Acquire** (promote) | the K8s Lease **and** at least `Qa` instance voters |

The sizes satisfy `Qa + Qs > n`, where n is the current number of instance voters and the holder's own vote counts. Defaults: `Qs = ⌊n/2⌋ + 1` (a majority) and `Qa = n − Qs + 1`. With n = 1 the instance path is disabled: the cluster is Lease-only, as in ADR-004.

### Why this is safe
Every acquire quorum overlaps every sustain quorum:
- Both contain the K8s Lease on the Lease path.
- On the instance path, `Qa + Qs > n` forces at least one shared instance voter.

A voter gives an unexpired grant to only one candidate at a time. So when a new candidate acquires, every way the old holder could sustain includes a voter that has moved on. The old holder can't renew there, and its last grant from that voter lapses before the voter re-grants. That holds because the holder treats a grant as valid only until request-send time + `renewDeadline`, fences within `fenceTimeout` after that, and `renewDeadline + fenceTimeout < leaseDuration`. This is the quorum-intersection argument from Flexible Paxos (Howard, Malkhi, Spiegelman, 2016): the quorum used for taking over must intersect the quorum used for holding on. Two quorums of the same kind don't have to.

There is still one mechanism and one timer: the holder fences when its valid grants no longer form *any* sustain quorum.

### Availability by topology (defaults)
| n | Qs / Qa | Primary keeps writing when… | Failover possible when… |
|---|---|---|---|
| 1 | Lease only | API server reachable | — (single instance) |
| 2 | 2 / 1 | API reachable (even with the replica dead), **or** the replica is reachable | API reachable + the candidate itself |
| 3 | 2 / 2 | API reachable (even with **both** replicas dead), **or** ≥ 1 replica reachable | API reachable + candidate + 1 other instance |
| 5 | 3 / 3 | API reachable, **or** ≥ 2 replicas reachable | API reachable + candidate + 2 others |

**Sequential failures go down to the last survivor.** When an instance has been failed for `voterRemovalDelay` (default 30 s, ≥ 2 × `leaseDuration`), the operator removes it from the voter set (see membership changes below). n shrinks, `Qa` shrinks with it, and failover stays possible: 3 → 2 → 1 surviving instances, as long as each failure is noticed before the next one.

**Simultaneous failures** (the primary and enough voters lost at once, e.g. n = 3 with the primary and one replica dead before removal) block automatic failover, with condition `QuorumUnavailable`. That's the price of surviving API-server outages. The survivor can't tell "they're dead" from "they're partitioned and still serving writes together". A human can force it with a PostgresSwitchover (`mode: Fast`) plus the annotation `pgkeeper.io/force-promote: <instance>`, after confirming the lost instances are really down (e.g. node gone). The operator then removes them from the voter set without their acknowledgement.

### Grants
A voter V grants candidate C a lease for term t only if:
1. t ≥ V's stored term, and
2. V holds no unexpired grant to a different candidate, and
3. C equals `status.targetPrimary` as last seen by V (cached; kept at its last value while the API server is unreachable), and
4. the request carries V's current `voterEpoch` (see membership changes).

A grant expires at V's monotonic now + `leaseDuration`. A renewal by the current holder extends it under the same rules, so a voter that sees `targetPrimary` move elsewhere stops renewing the old holder.

- **Instance voters** persist (candidate, term, voterEpoch) in PGDATA with fsync. A monotonic expiry can't survive a restart, so after restarting, a voter treats its persisted grant as freshly given and refuses other candidates for a full `leaseDuration`.
- **The K8s Lease voter** is today's lease: holder, plus `pgkeeper.io/term` and `pgkeeper.io/voter-epoch` annotations, updated by compare-and-swap on resourceVersion. Expiry is judged with client-go semantics (each observer's monotonic clock since its last observed change).

### Holder rule
Every `retryPeriod`, the holder renews with all voters in parallel. An independent deadline timer (not the renew loop) fences the instance when its valid grants form no sustain quorum: immediate stop, then SIGKILL after `fenceTimeout`.

### Failure detection (operator)
The operator declares the primary failed only when the holder **cannot** be sustaining:
- the K8s Lease has not changed for `leaseDuration`, **and**
- at least `Qa` instance voters positively report via `/v1/status` that their grant to the holder expired.

Together those reports form an acquire quorum, which overlaps every sustain quorum the holder could still be using. A voter the operator can't reach counts as "no report", never as "expired". So a primary cut off from the API server alone, but still sustained by its peers, triggers neither fencing nor failover.

### Membership changes
Membership changes cover scaling, voter removal after `voterRemovalDelay`, replacing a stranded instance (03 §11), and re-adding a recovered instance. The operator publishes the voter set with a monotonically increasing `voterEpoch` in `<cluster>-config`. A change uses **joint quorums**: until it completes, sustaining and acquiring must satisfy the rules under **both** the old and the new set.

A change completes when the current holder has renewed under the new `voterEpoch` with a sustain quorum of both sets. If there is no holder, it completes when an acquire quorum of the old set has acknowledged the new epoch. The forced removal described above is the only exception, and it needs a human. Exact commit rules are fixed and model-checked in Phase 10b before implementation (CLAUDE.md rule 4).

### Transport
Votes travel over the instance manager's mTLS API (`POST /v1/vote`, port 8000). Peers present an instance client certificate (CN `pgkeeper-instance`) signed by the cluster CA. The K8s Lease voter is reached through the API server as today.

### Rollout
`spec.ha.quorum.mode: KubernetesLease | Peers` and `spec.ha.quorum.voterRemovalDelay`.
- `KubernetesLease`: the instance path is disabled (n treated as 1), which is exactly ADR-004's behaviour. Built in Phase 8 on the voter abstraction.
- `Peers`: this ADR in full. Built in Phase 10b.
- Default is `KubernetesLease` until `e2e-chaos` with `Peers` has been green nightly for 7 days (the Phase 28 criterion). Then the default switches to `Peers`, recorded as an API change.
- `Qs`/`Qa` are fixed to the defaults in v1. A per-cluster override (e.g. favouring failover over outage survival) can be added later; CEL must then enforce `Qa + Qs > n`.

## Expected behaviour (acceptance for Phase 10b; defaults 15/10/2/3 s)
| # | n | Fault | Expected |
|---|---|---|---|
| F1 | 2, 3 | API server down | No fence, no failover; writes continue |
| F2 | 2, 3 | Primary cut off from the API server only | No fence, no failover |
| F3 | 2 | Replica killed | Primary keeps writing (Lease path) |
| F4 | 3 | Both replicas killed | Primary keeps writing (Lease path) — minimum availability |
| F5 | 2 | Primary killed | Failover to the replica (Lease + itself) |
| F6 | 3 | Primary killed | Failover (Lease + candidate + 1) |
| F7 | 2, 3 | Primary isolated from everything | Old primary fences ≤ 13 s after its last valid quorum; failover; overlap 0 s |
| F8 | 2 | Partition between A and B; both reach the API server | A keeps writing (Lease path); B can't acquire; no failover |
| F9 | 3 | API server down **and** one replica killed | Primary keeps writing (itself + 1 replica) |
| F10 | 3 | API server down **and** both replicas killed | Primary fences (no sustain quorum) |
| F11 | any | API server down **and** primary killed | No failover until the API server returns |
| F12 | 3 | Replica killed, then (after `voterRemovalDelay`) primary killed | Failover to the last survivor |
| F13 | 3 | Primary and one replica killed at once | No automatic failover; `QuorumUnavailable`; forced promotion works after human confirmation |
| F14 | any | Voter restarts mid-lease | No second grant within `leaseDuration`; no overlap |
| F15 | any | Scale 2→3→5→3 under write load | No overlap during joint-quorum transitions |
| F16 | any | Primary process frozen (SIGSTOP) > `leaseDuration` | Same as before: the lease can't prevent stale writes; only `dataDurability: Required` does (03 §3.6) |

## Alternatives rejected
- **Plain majority of instance voters** (with the K8s Lease as tie-breaker only for even n): a primary whose replicas are all down fences even though the API server is fine. That fails requirement 1 (F4).
- **CNPG-style isolation check** (fence only if the API server *and* all peers are unreachable): unsafe in a one-sided split, where peers reach the API server, take the lease and promote while the old primary still sees them.
- **K8s Lease normally, peer promises as a fallback during outages:** two mechanisms with a handover between them, the same shape as the two-timer bug in the Coroot study. The quorum lease is one rule evaluated by one timer.
- **Full Raft with a replicated log** (`etcd-io/raft`, `hashicorp/raft`): solves a bigger problem than we have; more state, harder to model-test.
- **Dedicated controller quorum per cluster** (KRaft dedicated mode): 3 extra pods per cluster (600 at the 200-cluster target).
- **Operator replicas as the quorum:** one central dependency with fleet-wide blast radius; doesn't remove the control-plane dependency.
- **Witness pod for 2-instance clusters:** works, but the K8s Lease already plays that role.

## Consequences
- A healthy primary is only fenced when it has lost **both** the API server and its sustain quorum of peers (ADR-015 row A8).
- Failover needs the API server plus `Qa` instances. Dead instances are removed from the voter set over time, so sequential failures still fail over down to the last survivor. Simultaneous failures need a human.
- Instance managers talk to each other: new client certs, NetworkPolicy allowance on port 8000 between instances, and failure modes that the model tests and the ledger chaos harness must cover.
- Membership changes become safety-relevant. Scaling and replacement logic in 03 §10–§11 must go through joint quorums.
- Process freeze (F16) is still not covered by the lease.
