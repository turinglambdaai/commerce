# Changelog

All notable changes to Commerce are documented here.

## Unreleased

### Added

- Add operator audit, claim reissue, the claim portal, and provider
  reconciliation on SQLite schema v7: an append-only audit table
  recording action/operator/reason/subject for every manual action; a
  rebuilt claim table that lets reissue append a fresh claim for the
  same issued credential with audited fresh tokens; a `/claims` HTTP
  endpoint fulfilling one-time tokens with typed 404/409/410 refusals;
  and `commerce/reconcile` comparing signed provider order-fact reads
  with projections into typed differences without ever mutating durable
  state. v1-v6 migrate in place.
- Add `commerce/server`, the HTTP webhook edge, and SQLite schema v6:
  the edge authenticates the exact request bytes, resolves the
  append-only durable checkout binding by order id, actively verifies
  the one-time order, journals idempotently, and acknowledges with a
  total status mapping (401/404/409/422/503) — with no issuance,
  signing, or delivery in the request path. v1-v5 databases migrate in
  place.
- Add subscription semantics on SQLite schema v5: the canonical payment
  event carries the provider-reported paid-through window; the projection
  advances to that window and emits one idempotently keyed renewal intent
  per new window (late events never shrink it); the Permit mapping gains
  the renew action and an explicit use-expiry so renewals lapse at the
  paid window and subscription cancellations expire at period end; the
  worker distinguishes renewals from second one-time purchases by the
  order projection and still refuses second one-time grants before
  signing. v1-v4 databases migrate in place.
- Add operational evidence tooling: `snapshot-commerce-database!` writes a
  consistent SQLite copy via VACUUM INTO while the service runs,
  `verify-commerce-backup` rehearses restores by checking integrity,
  database identity, schema version, and journal counts against the
  original, and `storage-retire-expired-claims!` transitions
  window-passed claims to their terminal expired state without deleting
  any durable evidence.
- Add `storage-readiness`, a single read-only snapshot of journal,
  projection, issuance-lease, and claim state, and `commerce/health`,
  which classifies it into typed stuck-work warnings
  (`projection-blocked`, `issuance-lease-expired`, `claim-window-passed`)
  with optional operator-visible logging. The future HTTP edge renders
  this value; nothing mutates.
- Add `raco commerce`, the operator CLI wrapping `commerce/operator`:
  `find` enumerates outbox work by status, `explain` prints a redacted
  JSON order story, and `redrive` makes one pending row due with typed
  nonzero-refusal exits.
- Add `commerce/log`, the single structured logging path:
  redacted-by-construction events with a closed whitelist of correlation
  keys and scalar field values, instrumenting journal acceptance and
  conflict, projection and blocking, lease claim/complete/release,
  redrive, and claim fulfillment or refusal. Raw bytes, tokens, and
  unlisted keys are rejected before emission; transport formatting stays
  a deployment concern.
- Add the runnable end-to-end journey (`examples/full-journey.rkt`) over
  the real protocol boundaries — authenticated Pancake webhook, actively
  verified one-time order, durable journal/projection, deterministic
  Ed25519 issuance, one-time claim fulfillment, refund withdrawal, and the
  operator explanation — plus the operator runbook
  (`docs/runbook.md`) covering paid-but-inactive, replay/redrive, refund
  reality, claim states, and the live sandbox drill.
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

