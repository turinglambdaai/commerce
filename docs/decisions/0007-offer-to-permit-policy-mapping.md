# ADR-0007: Versioned Offer-to-Permit policy mapping

- Status: Accepted
- Date: 2026-10-17

## Context

An issuance-outbox row identifies an Offer and an opaque subject, but it is not
authorization and does not contain a Permit credential. The issuer worker needs
one deterministic step that resolves reviewed product policy into a complete,
schema-valid Permit rights snapshot before any signing key is used.

Resolving a mutable "latest" policy would make a delayed or replayed purchase
change meaning. Removing an Offer definition after checkout would also strand
accepted payment evidence. Refund handling must preserve Permit entitlement
lineage instead of manufacturing a new unrelated credential or pretending an
offline credential was remotely revoked.

## Decision

`commerce/permit` is an explicit server-side adapter. It depends on the
published `permit` package's issuer snapshot constructors; the default
`commerce` facade remains independent of Permit.

A Permit policy revision has:

- an immutable stable policy id and positive audit version;
- one Permit subject type;
- one or more complete grant policies;
- the complete Permit constraints policy;
- the explicit one-time withdrawal response `expire-at-issuance`.

An Offer continues to reference one exact policy id. Policy ids are immutable:
changing rights creates a new policy id and version, then a new or updated Offer
definition. The catalog rejects duplicate ids, missing policy references, and
policies whose explicit product scope does not include the Offer's product.
The integer version is audit metadata, not a "select latest" mechanism.
Smart constructors detach and freeze caller-supplied strings, lists, hashes,
and Offer identifiers so later mutation cannot change a validated revision.

The catalog contains all active and retired Offer definitions still needed by
journal, outbox, or entitlement retention. Retiring an Offer from checkout does
not remove it from this catalog. A deliberately deleted Offer id is retained as
a tombstone and fails with `offer-deleted`; an id never known to the catalog
fails with `unknown-offer`. Deletion is therefore observable rather than
silently selecting another policy.

Preparing a `grant` requires no previous snapshot and creates a complete Permit
entitlement at revision 0. The caller supplies stable `credential_id` and
`entitlement_id` lineage identifiers plus the canonical issuance timestamp.
Preparing a `withdraw` requires the previous complete entitlement snapshot,
inherits its issuer, subject, grants, entitlement id, and next revision, and
sets `use_expires_at` to the new snapshot's `issued_at`. The successor is
usable no later than its issuance instant and is expired afterward, but an
older offline credential is not claimed to be revoked.

The adapter verifies that previous lineage issuer, entitlement id, subject type,
subject id, credential type, and grants match the requested operation. It
returns the validated snapshot and the exact bytes produced by Permit's single
serialization step. The later signer must sign those bytes without rebuilding
the JSON. Both the returned snapshot tree and byte string are immutable copies,
so caller mutation cannot make the two representations diverge.

All deterministic refusals use `exn:fail:commerce` codes and contain only safe
identifiers:

- `invalid-entitlement-policy`;
- `invalid-policy-catalog`;
- `invalid-entitlement-request`;
- `unknown-entitlement-policy`;
- `policy-offer-mismatch`;
- `unknown-offer`;
- `offer-deleted`;
- `unsupported-offer-kind`;
- `entitlement-lineage-required`;
- `entitlement-lineage-conflict`;
- `unsupported-rights-action`.

## Consequences

- Offer policy meaning is pinned by immutable id, not by processing time.
- Retired products can finish delayed fulfillment and refunds while true
  deletion remains an explicit operator-visible failure.
- Commerce reuses Permit's closed schema validation and does not copy its wire
  schema or sign credentials itself.
- Grant and withdrawal outputs are complete snapshots, never patches.
- This slice does not claim outbox work, allocate lineage ids, persist lineage,
  call `issue-credential`, access signing keys, or deliver credentials.
