# ADR-0003: SQLite event journal v1

Status: accepted, 2026-10-16

## Context

The pure core detects replay only inside one in-memory value. A webhook service
must not acknowledge an authenticated provider request until the evidence can
survive process loss. Independent developers also need an operational baseline
that does not require a separate database service.

The first persistence slice must not prematurely couple raw acceptance to order
projection, issuance outbox, Pancake networking, Permit signing, or claim
delivery.

## Decision

`commerce/journal` defines the backend-neutral acceptance and lookup contract.
`commerce/journal/sqlite` implements that contract for a filesystem SQLite
database. Neither module is re-exported from the product-safe `commerce`
facade.

Schema v1 uses SQLite `application_id` `COMM`, `user_version` 1, WAL mode, and
`synchronous=FULL`. One `commerce_event_journal` row stores:

- its monotonic local sequence;
- provider and provider event id;
- the exact authenticated request bytes and their SHA-256 digest;
- the complete provider-neutral payment-event snapshot;
- provider occurrence time and the original Commerce receive time.

`journal-accept!` copies and hashes the raw bytes before entering the backend.
Digest mismatch is rejected without a write. The SQLite backend performs lookup
and insertion inside an immediate transaction. A new key returns `accepted`
only after commit. An existing key returns `replayed` only when both the exact
raw bytes and canonical event match; otherwise it raises `event-conflict` and
preserves the original row. Receive time is observational metadata, so an exact
retry returns the first row and its first receive time.

Database triggers reject every `UPDATE` and `DELETE` against journal rows. The
public API exposes no mutation or enumeration operation. Future retention must
be an explicit, audited schema operation rather than ordinary application code.

## Consequences

- A webhook edge can use successful journal acceptance as its acknowledgement
  boundary without waiting for downstream work.
- Reopening the database reproduces the canonical event independently of later
  adapter changes.
- SQLite is the deployable single-node baseline, not a promise that every
  deployment must use SQLite; alternate backends implement the journal
  contract explicitly.
- Raw payloads may contain personal data. Operators must protect and back up the
  database accordingly and must not print payloads in ordinary logs.
- Signed 64-bit SQLite integer range is enforced at this backend boundary.
- Projection, outbox, provider networking, and Permit issuance remain future
  slices.
