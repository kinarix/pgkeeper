# 10 — Glossary (with intuition and examples)

**WAL (Write-Ahead Log)** — Postgres writes every change to a sequential log *before* changing data files. *Intuition:* a bank's journal — if the ledger pages burn, you rebuild them by replaying the journal. *Example:* `INSERT` → WAL record flushed → commit acknowledged → data page updated later at checkpoint.

**LSN (Log Sequence Number)** — a byte position in the WAL stream, written like `0/3000060`. *Intuition:* the odometer of the database; comparing LSNs tells you who is further ahead. *Example:* replica replayed `0/3000000`, primary at `0/3000060` → 0x60 = 96 bytes of lag.

**Streaming replication** — replicas connect to the primary and receive WAL continuously, replaying it to stay a near-identical read-only copy. *Intuition:* a live mirror of the journal being copied line by line.

**Replication slot** — a primary-side bookmark that prevents WAL a replica still needs from being deleted. *Intuition:* a "don't shred past this page" sticky note. *Risk:* a dead replica's slot makes WAL pile up until the disk fills — hence `max_slot_wal_keep_size`.

**Timeline** — a numbered branch of WAL history. Each promotion starts a new timeline. *Intuition:* git branches — after failover, the new primary is on branch 4 while the old one may have uncommitted work on branch 3. `.history` files record where branches forked.

**pg_rewind** — rolls an old primary's data directory back to the fork point so it can follow the new timeline without a full re-copy. *Intuition:* `git reset --hard` to the common ancestor, then pull. Writes made after the fork on the old primary are discarded.

**Primary / replica / promotion / demotion** — primary accepts writes; replicas are read-only; promotion turns a replica into the primary (`pg_promote()`); demotion stops a primary and restarts it as a replica.

**Switchover vs failover** — switchover is *planned* (old primary hands over cleanly: no data loss, seconds of downtime); failover is *unplanned* (old primary is dead or unreachable: possible data loss with async replication, tens of seconds).

**Split-brain** — two instances both accept writes, creating two incompatible histories. *Example:* both hand out order id 123456 to different customers; after healing, one branch is deleted and the id now points to another customer's row. Prevented by leases + fencing, fully closed for acknowledged writes only by synchronous replication.

**Fencing** — forcibly stopping a node that might still think it is primary. *Intuition:* taking the keys away from a driver before handing them to someone else. Here: IM runs `pg_ctl stop -m immediate`.

**Lease (Kubernetes `coordination.k8s.io/v1 Lease`)** — an API object recording who holds a role and when they last renewed. *Intuition:* a hotel key card that stops working unless re-validated every few seconds; nobody else gets a card for the room until the old one has certainly expired. The holder must give up before expiry if it can't renew.

**renewDeadline / leaseDuration / retryPeriod** — holder retries renewal every `retryPeriod`; a grant counts at the holder only until its renewal's send time + `renewDeadline`, after which (without a sustain quorum) it fences itself; voters hand the role to someone else only after `leaseDuration` has elapsed since they last granted it. Safety requires `renewDeadline + fenceTimeout < leaseDuration`.

**Quorum lease (ADR-016)** — the primary lease as granted by several **voters**: the Kubernetes Lease object plus the instance managers. *Sustain* (keep writing) needs the Lease **or** a majority of instances; *acquire* (promote) needs the Lease **and** enough instances that every acquire group overlaps every sustain group. *Intuition:* to keep the room you need either the front desk or most of your neighbours to vouch for you; to take the room you need the front desk and enough neighbours that at least one of them would have vouched for the previous guest. *Example:* 3 instances, API server down → primary keeps writing with one replica's vote; API up but both replicas dead → primary keeps writing on the Lease.

**DiskPressure / WALDiskPressure** — cluster conditions set when an instance's data (or WAL) volume passes `diskThresholds` (default 85 % warning, 95 % critical), measured by the IM itself so it works on any storage. *Why it matters:* a full `pg_wal` stops the primary.

**Shutdown handoff** — what the primary does on SIGTERM (pod delete, node shutdown): a clean fast stop, then it publishes the exact LSN where its WAL ends, and a replica that has received up to that LSN is promoted. *Intuition:* a relay runner who doesn't let go of the baton until the next runner has it. Zero lost commits, no `pg_rewind` (ADR-021).

**Crash loop (`CrashLoop`)** — the primary's Postgres crashed `maxRestarts` times within `window` (default 5 in 5 min), or didn't come back within `startTimeout`. A single crash is fixed by restarting in place; a crash loop means restarting won't help, so the IM releases the lease and the operator fails over (ADR-019).

**Backend OOM kill** — the kernel kills one Postgres backend for exceeding the memory limit; Postgres restarts all sessions (crash recovery) but the container keeps running, so restart counters don't notice. The IM reads the cgroup `oom_kill` count to catch it.

**Notification webhook** — optional HTTP endpoint (Slack-compatible or generic JSON) the operator calls for HA and storage incidents, so people get paged even without Alertmanager.

**Primary override (`PostgresPrimaryOverride`)** — a record the operator writes after every failover (and switchover) saying "this instance must stay primary". It beats the pin until a human deletes it. *Intuition:* a sticky note on the cluster saying "we moved the primary at 03:12 — acknowledge before moving it back". *Example:* pinned `orders-1` dies → `orders-2` promoted, override → `orders-2`; `orders-1` recovers but stays a replica until someone deletes the override, then a Graceful switchover moves the primary back.

**Voter / grant** — a voter is anything that can vouch for a primary (the Lease object or an instance manager). A grant is its time-limited vouch for one candidate; a voter holds at most one unexpired grant at a time.

**Term** — a number that increases every time leadership changes (like a Raft term or a Kafka leader epoch). Voters refuse requests with an older term, so a stale primary can't renew.

**Sustain quorum / acquire quorum (`Qs` / `Qa`)** — how many instance votes are needed to keep vs to take the primary role. `Qa + Qs > n` guarantees overlap. Defaults: `Qs` = majority, `Qa = n − Qs + 1`. This uneven-quorum idea is from Flexible Paxos.

**Tie-breaker** — the Lease object's vote: every promotion needs it, so when instances can't outvote each other (e.g. 2 instances) it decides. *Example:* 2 instances split by a network fault, both still reach the API server → the one renewing the Lease stays primary; the other can't take over.

**Joint quorum (membership change)** — while the voter set changes (scale, removing a dead instance), every decision must hold under both the old and the new set, so no moment exists where two disjoint groups could each elect a primary.

**Voter removal (`voterRemovalDelay`)** — an instance failed for longer than this is removed from the voter set, shrinking the quorums so later failures can still fail over, down to the last survivor.

**Synchronous replication (quorum)** — the primary waits for N standbys to confirm receipt before acknowledging a commit. `ANY 1 (a, b)` = any one of a/b must confirm. *Trade-off:* durability vs latency/availability. *Required* mode blocks writes if confirmations are impossible.

**RPO / RTO** — Recovery Point Objective (how much recent data you may lose: "≤ 5 s of writes"); Recovery Time Objective (how long until service resumes: "≤ 30 s").

**Base backup** — a copy of the data directory taken while the database runs, plus the WAL needed to make it consistent. *Intuition:* a photo of a moving train plus the video clip around the photo's moment.

**Delta / incremental backup** — stores only pages changed since a parent backup. *Example:* Sunday full (100 GB) + Monday delta (3 GB) + Tuesday delta (2 GB); restore fetches all three. WAL-G calls these delta backups; PG17 has native incremental (`pg_basebackup --incremental` + `pg_combinebackup`).

**WAL summarization (`summarize_wal`, PG17+)** — Postgres records which blocks changed per WAL range, which makes native incremental backups cheap to compute.

**WAL archiving / `archive_command`** — Postgres hands each completed WAL segment to a command that uploads it. *Intuition:* every page of the journal is photocopied to the vault as soon as it is full. `archive_timeout` forces a new segment even when idle.

**PITR (Point-in-Time Recovery)** — restore a base backup and replay archived WAL up to a chosen moment (time, LSN, transaction id, named restore point). *Example:* someone ran `DELETE FROM orders` at 21:31; restore a new cluster to 21:30:59.

**Instance manager (IM)** — this project's agent binary running as PID 1 in each Postgres container; it bootstraps, configures, supervises, fences, promotes, archives and reports.

**PID 1** — the first process in a container. Special: receives signals for the container, must reap zombie processes, and when it exits the kernel kills everything else in the container.

**Image volume** — a Kubernetes volume type that mounts an OCI image's filesystem read-only into a pod (beta default-on in 1.35, GA in 1.36). *Use here:* ship `pgkeeper-instance` + `wal-g` into the unmodified official Postgres image.

**`extension_control_path` (PG18+)** — lets Postgres find extensions outside its install directory, so extensions can be mounted from image volumes instead of baked into the image.

**Reconciliation loop / controller** — a function that repeatedly compares desired state (CR spec) with actual state and makes one step towards desired. *Intuition:* a thermostat, not a script. Must be idempotent.

**Drift** — actual state diverging from declared state without going through the spec (someone edits a Service, runs `ALTER ROLE`, deletes a slot). Repaired by re-applying desired state on watch events and periodic resync.

**Server-side apply (SSA)** — Kubernetes merges your declared fields and tracks which "field manager" owns each field. Re-applying the full desired object corrects drift in owned fields and leaves others' fields alone.

**Owner reference / garbage collection** — metadata linking a generated object to its owner; deleting the owner deletes children automatically.

**Finalizer** — a marker that blocks deletion of an object until the controller has done cleanup (e.g. drop role in Postgres), then removes the marker.

**CEL validation (`x-kubernetes-validations`)** — expressions embedded in the CRD that the API server evaluates on create/update. *Example:* `self.renewDeadline + self.fenceTimeout < self.duration`; `self == oldSelf` for immutable fields. Avoids running a validating webhook.

**ValidatingAdmissionPolicy (VAP)** — cluster-level CEL policies that can reference the requesting user, e.g. "only group dba may change `spec.primary`".

**Status conditions** — standardized `type/status/reason/message` entries on `status.conditions`, e.g. `Ready=False reason=PrimaryMissing`. Machines and humans both read them.

**PodDisruptionBudget (PDB)** — limits voluntary disruptions (drains), e.g. "at most 1 replica down".

**EndpointSlice** — the objects that tell kube-proxy which pod IPs back a Service; after relabelling the primary there is a short propagation delay before `-rw` routes to the new pod.

**SCRAM-SHA-256 verifier** — a salted, iterated hash stored by Postgres instead of the password. The server can check a login but can't recover the password. Computing it in the operator means the plaintext never reaches Postgres or its logs.

**pg_hba.conf** — Postgres' host-based authentication rules: first matching line (connection type, database, user, address) decides the auth method.

**`allow_alter_system` (PG17+)** — when `off`, `ALTER SYSTEM` is rejected, so config can't drift from the operator's files.

**jsonlog (PG15+)** — Postgres log format with one JSON object per line; easier to categorize than text logs.

**pgaudit** — extension producing structured audit records for DDL, role changes, reads/writes; not in the official image.

**envtest** — runs a real kube-apiserver + etcd locally (no nodes) so controllers can be tested against the real API, CRDs and CEL rules.

**Chainsaw** — declarative YAML end-to-end test runner for operators (Kyverno sub-project): create resources, assert on cluster state.

**Chaos Mesh** — Kubernetes chaos engineering tool to inject network partitions, pod kills, IO latency, clock skew.

**Ledger test** — writers record every acknowledged commit in an external "truth" database; after a fault you compare the surviving cluster against the ledger to count lost and stolen writes and detect overlapping primaries.

**kind / k3d (k3s)** — local Kubernetes clusters in Docker containers; kind runs upstream Kubernetes, k3d runs Rancher's lightweight k3s distribution.

**local-path storage** — node-local PersistentVolumes (default in kind and k3s); fast and simple but tied to one node — a pod can't move if its node dies.

**WAL-G** — Go tool for Postgres WAL archiving and base/delta backups to S3, GCS, Azure, Swift, SSH or filesystem.

**Barman / barman-cloud** — EDB's Python backup and recovery tools for Postgres (backup-only, no HA); CloudNativePG uses barman-cloud via a plugin sidecar.

**CloudNativePG (CNPG)** — open-source CNCF Postgres operator; prior art for many patterns here (instance manager, lease, isolation check).

**Patroni** — Python HA manager for Postgres using a distributed config store (etcd/Consul/Kubernetes) as lock; requires Python in the image.
