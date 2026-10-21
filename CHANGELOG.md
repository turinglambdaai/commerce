# Changelog

All notable changes to Commerce are documented here.

## Unreleased

### Added

- Add the `commerce/operator` replay surface: redacted order explanations
  (projection, canonical event snapshots, outbox work, issued-credential
  evidence), status-filtered outbox enumeration, and bounded redrive that
  makes pending work due without touching attempts, rewinding in-flight or
  completed work, or editing projection rows.
- Add one-time claim delivery on SQLite schema v4: an append-only
  issued-credential record retaining the exact signed envelope bytes, a
  claim table storing only the SHA-256 digest of a random one-time token,
  ready/claimed/expired fulfillment states with idempotent notification
  marks, and typed claim fulfillment that returns the signed bytes without
  ever advancing a lineage revision. The worker's completion transaction
  records the credential and its claim atomically; v3 databases migrate in
  place. No HTTP listener, transport, or portal is included.
- Add the explicit `commerce/issuer` worker: deterministic entitlement and
  credential id derivation, version-pinned snapshot preparation, and
  deterministic Ed25519 signing of the exact recorded bytes outside the claim
  transaction. Deterministic dead ends are refused and released with typed
  codes before any signing; Permit signing failures release as
  `permit-issue-failed` with bounded backoff and complete after operator
  repair; a lost lease between claim and completion reports `lease-lost` and
  writes nothing. No signed credential bytes, delivery tokens, or HTTP
  listeners are included.
- Add an owner-safe issuance-outbox lease state machine: exclusive claim in
  one immediate transaction with observable attempts, expired-lease reclaim,
  owner-checked completion, and typed release with a bounded retry time.
  Completion appends the lineage root plus revision zero, or exactly one
  successor, in the same transaction that completes the outbox row, binds the
  pinned policy id/version and deterministic lineage ids, computes the payload
  digest server-side, and reconciles repeated completion to the recorded
  revision. Lineage and revision readers expose durable audit state. No
  signing, signed-credential persistence, delivery, or HTTP listener is
  included.
- Add SQLite schema v3 with immutable entitlement roots and contiguous Permit
  revision evidence. Fresh, v1, and v2 databases migrate atomically without
  rewriting journal/outbox evidence; no lease worker, signer, signed credential,
  or delivery behavior is implied.
- Add validated, version-pinned Offer-to-Permit policy mapping for one-time
  grants and issuance-expiring withdrawal successors. Active and retained
  retired Offers resolve deterministically; unknown, deleted, mismatched, and
  invalid policy or lineage inputs fail with typed Commerce errors before
  signing.
- Add SQLite schema v2 with replayable order projection, durable projection
  outcomes, and transactional issuance-outbox insertion. Schema v1 migrates in
  place, deterministic conflicts become durable blocked work, and injected
  write failures prove order/outbox/marker rollback as one unit.
- Add signed Pancake merchant GraphQL reads and active one-time-order
  verification. A completed order must match its webhook, environment, store,
  checkout binding, product, succeeded payment, currency, and exact minor-unit
  amount before `commerce/pancake` constructs a canonical payment event.
- Add `commerce/pancake`, an explicit exact-byte RSA-SHA256 webhook verifier
  with test/production key isolation, asymmetric replay windows, mode binding,
  duplicate-field rejection, redacted typed failures, and independently
  checked protocol fixtures.
- Add a backend-neutral durable journal contract and a SQLite v1 backend that
  stores exact authenticated bytes plus canonical event snapshots, verifies
  payload digests, distinguishes accepted/exact/conflicting replay, and blocks
  row mutation or deletion at the database layer.
- Align Commerce with the canonical five-repository architecture, including
  the one-way Permit issuer adapter, product/identity boundary, and a bounded
  M1 implementation handoff.
- Add a documentation gate for local links and canonical family-architecture
  references.
- Define the provider-neutral Commerce boundary and its relationship with
  Rivet, Glaze, Keel, and Permit.
- Add the pure payment-event projection core with idempotent replay,
  conflicting-replay rejection, refund-before-payment handling, and rights
  intents.
- Add the server-side provider adapter contract and runnable first-purchase
  walkthrough.
- Add bilingual onboarding, a canonical documentation map, security and
  operations contracts, ADRs, and three-platform CI.

