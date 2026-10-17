# ADR-0006: SQLite order projection and issuance outbox

- Status: Accepted
- Date: 2026-10-17

## Context

The immutable journal proves that Commerce accepted an authenticated payment
fact, but it does not yet make the commercial transition durable. Updating an
order and then separately creating issuance work would leave a crash window in
which a paid order exists without a credential request, or a retry creates the
same request twice.

Webhook acknowledgement must remain independent of signing and delivery. The
journal commit therefore stays the acknowledgement boundary; projection is a
separate, replayable phase driven entirely from durable journal rows.

## Decision

Schema v2 adds three tables beside the immutable v1 journal:

- `commerce_order_projection` stores the current rebuildable commercial view
  for `(provider, order_id)`;
- `commerce_projection_event` records whether one journal sequence was
  `projected` or `blocked`, including a typed failure code for operator review;
- `commerce_issuance_outbox` stores each emitted rights intent under its stable
  idempotency key and the source journal sequence.

One projector transaction uses `BEGIN IMMEDIATE`, selects the lowest journal
sequence with no projection-event row, loads the current order, applies the
same pure transition as `commerce/core`, and then performs all of the following
before commit:

1. insert or update the order projection;
2. insert every newly emitted rights intent into the issuance outbox;
3. mark the source journal sequence projected.

The outbox uniqueness key is the rights intent idempotency key. Exact webhook
replay creates no new journal sequence. Projector replay after process loss
either sees the committed projection marker or repeats the entire rolled-back
transaction, so neither path can duplicate issuance work.

An order identity conflict is deterministic poison work, not a transient
failure. The transaction preserves the previous order, emits no outbox row,
and records the journal sequence as `blocked` with `order-conflict`. Unexpected
database or process failure rolls back without a marker and is retried from the
same sequence.

Schema v1 databases migrate in place to v2 inside one immediate transaction.
Existing journal rows remain byte-for-byte unchanged and become pending
projection work. Unknown application ids or schema versions still fail closed.
The service persistence surface is renamed to `commerce/storage` and
`commerce/storage/sqlite`; journal operations consume the same opaque storage
handle. The old SQLite-journal-only module is removed rather than maintained as
a second compatibility track.

Outbox rows begin as `pending`, with zero attempts, `available_at` equal to the
projection time, and no lease. A later Permit worker will claim work in a short
transaction by changing it to `processing`, incrementing attempts, and setting
an opaque owner plus an expiry. Active leases are exclusive; expired leases
are reclaimable. Signing and credential persistence happen outside the claim
transaction, followed by an owner-checked completion transaction. That worker
API and all Permit data remain outside this slice.

## Crash points and recovery

- After journal commit but before projection: the sequence remains selectable.
- During order, outbox, or marker writes: SQLite rolls back all three.
- After projection commit but before the caller observes success: the marker
  and unique outbox key make the retry a no-op.
- During a future issuance lease: expiry makes the pending durable intent
  reclaimable; idempotent Permit issuance remains mandatory.

## Consequences

- Acknowledging a webhook never waits for Permit signing or delivery.
- Orders and issuance intents cannot diverge through a local transaction crash.
- Blocked commercial conflicts are durable and inspectable instead of becoming
  an infinite retry loop.
- Projection is rebuildable from immutable journal rows; outbox state is
  workflow state and is not authorization evidence.
- This slice does not resolve Offer policy, call Permit, issue or deliver a
  credential, expose an HTTP listener, or claim a complete refund workflow.
