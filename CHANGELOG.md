# Changelog

All notable changes to Commerce are documented here.

## Unreleased

### Added

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

