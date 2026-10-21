# ADR-0010: Explicit issuer worker

- Status: Accepted
- Date: 2026-10-21

## Context

ADR-0009 delivered the owner-safe lease and the transactional lineage
writer, but nothing turned a claimed outbox row into a signed Permit
credential. The remaining risks were exactly the ones ADR-0008 deferred:
key custody, ambiguous signing recovery, and the temptation to sign inside
a webhook or leak the signer into product-facing modules.

## Decision

`commerce/issuer` is an explicit server-side worker module. It may import
`permit/issuer`; the default `commerce` facade still does not.

`make-issuance-worker` binds one reviewed policy catalog, one issuer
identity, one Ed25519 private key, its trust-store key id, and the trust
store behind a single worker value. The private key stays in memory and is
never exposed by an accessor. `process-issuance-work!` claims one due row
through the storage lease and drives it to completion:

1. Resolve the pinned Offer policy and fail deterministic dead ends
   (`unknown-offer`, `offer-deleted`, `unsupported-offer-kind`,
   second grant over a lineage, withdrawal without a lineage) before any
   signing work, releasing the row with the typed code and an operator
   backoff.
2. Derive the deterministic entitlement id — from issuer, subject type,
   subject, and Offer — or reuse the recorded lineage's id, then load the
   latest revision.
3. Prepare the complete snapshot through `commerce/permit`: revision zero
   for a grant with no previous, or a successor naming the latest revision
   and expiring at issuance for a withdrawal. The withdrawal's previous
   snapshot is parsed from the recorded revision's exact unsigned bytes.
4. Sign the exact recorded bytes with `permit/issuer` outside the claim
   transaction. Ed25519 signing is deterministic, so a crash after signing
   is safe: the reclaiming worker re-signs identical bytes and converges on
   the same signature. The signed envelope is deliberately not persisted;
   durable evidence stays the unsigned payload per ADR-0008.
5. Complete through `storage-complete-issuance-work!`. Losing the lease
   between claim and completion reports `lease-lost` to the caller and
   writes nothing; the new owner's signing path reconciles.
6. Release transient signer failures (`permit-issue-failed`) with a bounded
   backoff so the same durable work completes after operator repair.

Entitlement and credential ids are derived deterministically
(`derive-entitlement-id`, `derive-credential-id`) so reprocessing never
allocates a second lineage or revision. A deterministic clock parameter
makes the whole worker reproducible in tests; production uses wall-clock
UTC RFC 3339 timestamps that correspond to the recorded epoch second.

## Failure and retry contract

- Deterministic mapping refusals release with the commerce code and an
  operator-scaled backoff; they never burn signing attempts.
- `exn:fail:permit:issue` releases as `permit-issue-failed` with a short
  backoff. Key, window, purpose, and trust-store repair are operator work;
  after repair the same row completes with its attempts counter intact.
- `lease-not-held` at completion returns `lease-lost` and mutates nothing.
- No path persists signature bytes, delivery tokens, or customer contact
  data in this boundary; claim delivery remains a future slice.

## Consequences

- M1's issuance half is honest: signed evidence is reproducible from
  recorded bytes, but no credential has been delivered anywhere.
- The worker keeps Commerce's one-way dependency: `commerce/issuer` imports
  `permit/issuer`; Permit never imports Commerce.
- Delivery, credential persistence, and the HTTP edge stay out of this
  decision and remain the next bounded slice.
