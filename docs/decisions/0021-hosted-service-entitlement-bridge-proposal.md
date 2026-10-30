# ADR-0021 (proposed): Product-neutral hosted-service entitlement bridge

- Status: **proposal / interface design only**, not a shipped Commerce API.
- Consumer pilot: [Publy #17](https://github.com/turlamai/publy/issues/17), [Commerce #21](https://github.com/turlamai/commerce/issues/21)
- Date: 2026-10-30

## Problem

Commerce already authenticates provider evidence, journals raw events, projects
orders, drives issuance outbox work, signs Permit snapshots through the explicit
issuer worker, and delivers an exact signed credential through one-time claims.
The current `commerce/server.rkt` exposes only a Pancake webhook, `/readyz`
and `/claims`. It **does not** expose an authenticated product-scoped way to
query the *current* entitlement revision and state.

A hosted product such as Publy needs real-time server-side authorization for
paid publish jobs. A checkout redirect, claim token, public order id, API key,
email, cached signed snapshot or historic paid status does not establish
current access after a refund, cancellation or account disablement.

## Ownership and trust

- Product establishes the stable, opaque subject id from its authenticated
  account. It keeps mutable product state, publication quotas, account binding,
  job admission, and the free local/self-hosted functionality.
- Commerce owns provider evidence, immutable journal, Offer mapping, payment
  period projection, issuance orchestration, current lineage metadata and audit.
- Permit owns signed credential format, trusted issuer keys and validation.
  A Commerce response alone must not become permission to unlock software.
- The Publy plugin, CLI and browser are **not** authoritative callers of this
  bridge. The Publy server is the only intended consumer; issuer keys stay out
  of both the HTTP edge and client applications.

Do not add Commerce dependencies to Rivet, Glaze, Keel or Permit; the product
uses a dedicated server-side adapter instead of bundling Racket in Obsidian.

## Proposed query semantics (not an implemented endpoint)

An authenticated, product-scoped server-to-server **read** asks for a verified
`(product-id, subject-type, subject-id, offer/scope)`. The response may state:

- `active`: the current payment/entitlement projection and latest validated
  Permit lineage revision agree and authorize the named scope at evaluation
  time; include exact subject, product, issuer, credential/entitlement id and
  revision, evaluated-at and valid-until, plus a verified signed envelope or
  its validated reference;
- `inactive`: not purchased, expired, cancelled at period end, withdrawn,
  suspended or otherwise ineligible (typed reason without raw provider data);
- `pending`: provider evidence/issuance/outbox is not yet reconciled;
  callers must not grant paid access;
- `unavailable`: authoritative query could not be completed. Fail closed
  for paid job admission; free local features remain available.

Return the least privileged data required, never a claim token, private
signing key, provider payload, email, API key or mutable catalog definition.
An old signed envelope is insufficient without checking the **latest**
revision and current withdrawal/suspension/payment projection.

## Required authorization and consistency proof

Before naming a stable route or public schema, implement and test all of:

1. Authenticate the **calling product service**, not an end-user bearer key:
   distinct credentials per deployment, scoped by product and environment,
   encrypted transport, bounded clock skew, replay protection, rate/size
   limits, no raw credentials in logs.
2. Match requested product, stable subject, issuer, entitlements, Offer policy
   and environment to reviewed server mappings. Reject subject substitution.
3. Return one coherently observed snapshot of order projection and latest
   issuance revision; if it cannot be made coherent, return `pending` rather
   than a stale `active`. Avoid holding long SQLite transactions open during
   network calls.
4. Reconciliation and refund/chargeback/cancel transitions must become
   observable to new product admissions. Document the expected freshness and
   bound any caches; no indefinite positive cache.
5. Product meters quotas **atomically** at scheduling and execution boundaries,
   using its own durable ledger. Commerce must not embed Publy plan labels,
   WeChat quotas, local path controls or UI text.
6. Test cross-product and cross-account access, expired term, pending
   payment, duplicate and out-of-order callbacks, refunded entitlement,
   stale revision replay, suspended user, long queue, outage, process crash,
   restore and key rotation with deterministic fixture evidence.
7. Admit a real provider only after [ADR-0019](0019-provider-admission.md)
   and merchant evidence. Mock checkout/claim fixtures are not live sales.

## Incremental delivery

1. Characterize existing `commerce/storage` and issuance/claim read surfaces
   and document any missing read model; don't duplicate Permit parsers.
2. Add pure server-side decision logic with fixture tests and **no HTTP**
   endpoint until semantics are proven.
3. Add scoped service authentication and a narrow HTTP read API behind
   explicit opt-in; test security and unavailable behavior.
4. Integrate Publy in shadow mode without paid admission, proving account
   mapping and migration from its legacy local orders/expiry.
5. Stage merchant approval, deployment, reconciliation, backup/recovery and
   live purchase/claim/refund. Only then permit a separate production launch.

No implementation, billing activation, release tag or production approval is
claimed by this ADR proposal.
