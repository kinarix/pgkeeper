# ADR-014 — Role passwords delivered as SCRAM-SHA-256 verifiers computed by the operator

- Status: Accepted
- Date: 2026-10-15
- Related: 05 §1.1

## Context
Sending plaintext passwords to Postgres risks them appearing in Postgres logs or statement records.

## Decision
The operator computes a SCRAM-SHA-256 verifier from the Secret and sends only the verifier to the IM.

## Alternatives rejected
- **Sending plaintext to the IM / `ALTER ROLE ... PASSWORD '<plaintext>'`.**

## Consequences
Plaintext never leaves the Secret/operator process and never appears in Postgres logs. The IM cannot compare plaintext, so change detection relies on the verifier and the Secret's resourceVersion.
