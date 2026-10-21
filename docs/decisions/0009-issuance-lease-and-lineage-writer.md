# ADR-0009: Issuance outbox lease state machine and transactional lineage writer

- Status: Accepted
- Date: 2026-10-21

## Context

ADR-0008 reserved the append-only entitlement lineage schema. Without a
writer, outbox rows can only be inserted as `pending`, and withdrawals cannot
advance a lineage. The remaining question was the exact ownership protocol:
how a worker claims work, how completion becomes durable, and what happens
when a worker dies mid-flight.

This decision deliberately stops before Permit signing. No private key is
loaded, no signer is called, no signed credential bytes are persisted, no
claim is delivered, and no HTTP listener is added. Those belong to the
explicit issuer worker that this protocol enables.

## Decision

The storage contract gains three owner-checked operations plus lineage and
revision readers:

- `storage-claim-issuance-work!` claims the lowest due outbox row in one
  immediate transaction: it sets `processing`, increments `attempts`, and
  binds an opaque `lease_owner` and `lease_expires_at`. A row is due when it
  is `pending` with `available_at <= now`, or `processing` with an expired
  lease. Active leases are exclusive; expired leases are reclaimable by any
  owner, including the previous one.
- `storage-complete-issuance-work!` appends the lineage root together with
  revision zero, or exactly one successor revision, and completes the outbox
  row inside the same short immediate transaction. The claimed item carries
  the lease owner; completion re-checks owner and expiry against the
  database before writing. The revision binds the pinned policy id/version,
  the deterministic credential id, the entitlement id, and the exact
  unsigned payload bytes; the payload digest is computed by the writer, not
  trusted from the caller.
- `storage-release-issuance-work!` returns a claimed row to `pending` with a
  typed error code and a future `available_at`. Only the lease owner may
  release; `attempts` is left exactly as the claim incremented it.

Identity and contiguity rules follow ADR-0008 and are enforced by the writer
as typed failures before any insert: a commercial identity already bound to
a different entitlement id, a second grant over an existing lineage, a
withdrawal without a lineage, and a credential id already bound to another
revision all fail with `entitlement-lineage-conflict` or
`entitlement-lineage-required` and write nothing.

Completion is reconciling by construction. If the outbox row is already
completed, repeating the same completion returns the recorded revision, so a
worker that crashes after the commit simply retries; the same outbox id with
a different payload is a conflict, never a second revision. Because the
revision append and the outbox completion share one transaction, there is no
durable state in which a revision exists while its work is still pending.

## Failure and retry contract

- Lease lost (expired, reclaimed, or never held): `lease-not-held`; the
  caller must stop operating on that row. No partial write is possible
  because the check and the writes share the transaction.
- Deterministic failures (identity conflict, missing lineage, unknown work)
  raise typed codes and leave the row untouched. They are operator work, not
  retry fuel.
- Transient failures are released with a typed error code and a caller
  chosen bounded `available_at`. This layer does not impose backoff policy;
  the future worker does.
- Signing occurs outside the claim transaction in the future worker, so the
  ambiguous-crash window stays exactly where ADR-0008 places it: before
  completion, reconciled by the deterministic credential id and the recorded
  revision.

## Consequences

- SQLite enforces exclusive, observable, owner-safe issuance ownership
  without a background process.
- The future issuer worker only adds snapshot preparation, the signer call,
  and delivery; it cannot invent a second lineage or skip a revision because
  the writer already forbids both.
- Outbox rows remain `pending`, `processing`, or `completed`. Terminal
  deterministic refusal still has no dedicated status; bounded worker retry
  and operator-visible error codes cover it until evidence shows a terminal
  status is needed.
