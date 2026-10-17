# ADR-0008: SQLite entitlement lineage v3

- Status: Accepted
- Date: 2026-10-17

## Context

Permit snapshot preparation is deterministic, but a withdrawal cannot safely
derive its successor from an outbox row alone. Commerce must retain the stable
entitlement identity, every issued revision, the exact unsigned payload bytes,
and the outbox work that caused the revision. A process restart or retry must
never allocate a second lineage or skip a revision.

This change deliberately stops before worker mutations and signing. Defining
the durable evidence first keeps key custody, lease ownership, and ambiguous
signing recovery out of the schema migration transaction.

## Decision

SQLite schema v3 adds two append-only tables:

- `commerce_entitlement_lineage` owns the stable entitlement id and binds it to
  issuer, subject type/id, Permit credential type, and Offer;
- `commerce_entitlement_revision` records one complete unsigned Permit payload,
  SHA-256 digest, credential id, pinned policy id/version, issuance time, and
  unique source issuance-outbox row.

The commercial identity tuple is unique, so the same issuer, subject, Permit
credential type, and Offer cannot silently acquire a second lineage. Revision
zero must be a `grant` with no predecessor. Every later row names revision
`n - 1` through a self-referencing foreign key, which rejects gaps. Credential
ids and source outbox ids are unique across all revisions.

Both tables reject ordinary `UPDATE` and `DELETE`. A later writer must append
the lineage root and revision zero together, or append exactly one successor,
inside a short transaction. Repair and retention require an explicit future
schema operation rather than mutable audit history.

`payload_bytes` contains the exact unsigned bytes returned by
`prepare-permit-snapshot`; it is not a signed credential. The schema stores no
signature, private key, signed credential bytes, delivery token, or customer
contact data.

Fresh databases create v3 directly. Existing v1 databases create the v2
projection/outbox tables and v3 lineage tables in one immediate transaction.
Existing v2 databases add only the lineage tables. Journal, projection, and
outbox rows are not rewritten.

## Failure and retry contract

- A migration crash rolls back its DDL and version change together; reopening
  retries the same migration.
- Invalid policy, missing predecessor, identity conflict, or malformed payload
  is deterministic operator work and must fail before signing.
- Signer or secret-store unavailability is transient future worker work; it
  must retain the outbox row and use bounded backoff.
- A crash after signing is ambiguous. A future worker must reconcile the
  deterministic credential id and lineage revision before attempting another
  signature or completion.
- Delivery failure occurs after durable issuance and must never create another
  entitlement revision.

## Consequences

- SQLite can enforce immutable, contiguous lineage evidence independently of a
  future worker implementation.
- Exact snapshot bytes remain available for successor preparation and audit
  without pretending that a credential was signed.
- The next slice can focus on an owner-safe outbox lease and transactional
  lineage writer.
- No public storage mutation API, lease claim, signing, credential persistence,
  or delivery behavior is added by this decision.
