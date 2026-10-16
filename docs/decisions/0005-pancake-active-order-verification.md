# ADR-0005: Pancake active one-time order verification

- Status: Accepted
- Date: 2026-10-16

## Context

A valid Pancake webhook signature proves who sent a byte sequence. It does not
by itself prove that the referenced order is still present, completed in the
selected environment, belongs to the expected store and product, or charged
the amount Commerce intends to exchange for one Offer. Fulfilment therefore
needs a fresh provider read after webhook authentication.

The protocol baseline is the official
[Waffo Pancake Go SDK v0.17.0](https://github.com/waffo-com/waffo-pancake-sdk-go/tree/v0.17.0)
and its
[GraphQL guide](https://github.com/waffo-com/waffo-pancake-sdk-go/blob/v0.17.0/docs/graphql-guide.md),
released on 2026-10-10. The SDK defines merchant reads as signed `POST`
requests to `https://api.waffo.ai/v1/graphql`. Test and production use this
same endpoint. The merchant-key context and the returned order's `testMode`
field provide environment separation; Commerce never infers an environment
from a hostname.

## Decision

`commerce/pancake` owns a narrow merchant client for the one-time-order query.
Every request sends `X-Merchant-Id`, a decimal seconds `X-Timestamp`, and an
`X-Signature`. The signature is Base64-encoded RSA-SHA256 with PKCS#1 v1.5 over:

```text
POST + "\n" + /v1/graphql + "\n" + timestamp + "\n"
  + BASE64(SHA256(exact request body))
```

The read sends no idempotency key, follows no redirects, and makes one network
attempt. Connect and complete-response timeouts are bounded. Commerce does not
retry inside the adapter: a timeout or provider `429`/`5xx` becomes the typed,
retryable `pancake-order-unavailable` failure so the durable worker can retry
the whole authenticated event with its own bounded backoff and observability.
Authentication failures, rejected queries, missing orders, malformed
responses, and semantic mismatches use separate redacted failure codes.

The authoritative query selects only the fields needed for the trust decision:

- order `id`, `status`, `testMode`, `currency`, and
  `orderMerchantExternalId`;
- owning store `id` and one-time product `id`;
- payments' `id`, `status`, and `snapshotAmountDetails { currency total }`.

For an authenticated `order.completed` webhook, Commerce requires exactly one
matching payment whose id is the webhook business `eventId`. The order must be
`completed`, the payment must be `succeeded`, and order id, store id,
environment, product id, currency, payment currency, and charged total must all
match the server-side binding. Display money is parsed as a strict non-negative
decimal into exact minor units using the binding's explicit ISO 4217 exponent;
floating point never enters the comparison.

The server-side binding contains a random `orderMerchantExternalId` created for
checkout and associated locally with one stable subject and Offer. The active
order must echo that value. It is a correlation capability, not the subject id
itself. Buyer email, Pancake customer identity, webhook metadata, redirects,
and client claims are never used as authorization identity.

Only after all checks pass may the adapter construct a canonical
`payment-event`. Its durable delivery id is the webhook envelope `id`; the
webhook business `eventId` identifies the payment used by the active query.

## Consequences

- A forged, stale, cross-environment, cross-store, product-substituted,
  identity-substituted, or amount-substituted order fails closed before journal
  acceptance or rights projection.
- A local checkout-binding record is a prerequisite for fulfilment; accepting
  arbitrary metadata as a subject is forbidden.
- Unit and protocol tests use an injected deterministic transport and disposable
  RSA keys. They do not claim live Pancake sandbox certification.
- Durable binding storage, order projection, outbox insertion, HTTP ingress,
  reconciliation scheduling, Permit signing, and claim delivery remain later
  slices.
