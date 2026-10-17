# Changelog

All notable changes to Commerce are documented here.

## Unreleased

### Added

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

