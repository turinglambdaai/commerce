# Alipay Vibe Pay Basic Collection: implementation and deployment

- Provider: `alipay`
- Status: **protocol-core candidate only**; not merchant-admitted, not a production checkout
- Initial use case: **CNY one-time desktop/web purchases** opening the browser.
- References: [Vibe Pay](https://aipay.alipay.com/products/vibe-pay),
  [web integration guide](https://aipay.alipay.com/docs/vibe-pay/ai-web-app-payment-qianyi/ai-web-app-payment-integration-guide.html),
  [ADR-0019](decisions/0019-provider-admission.md),
  [Commerce #23](https://github.com/turlamai/commerce/issues/23).

## Implemented bounded slice

`commerce/alipay.rkt` is a Racket server-only RSA2 notification and payment
confirmation **boundary**. It has no network side effects and never reads a
merchant private key.

1. Accept a **duplicate-preserving decoded field association list**. Reject
   duplicate field names, missing signature, non-RSA2 mode and invalid RSA2
   signature. Build the ordered `key=value&...` signing representation
   excluding `sign` and `sign_type`. Verify using the pinned Alipay public
   key; do not use the merchant public key to verify callbacks.
2. Convert CNY decimal to exact fen, rejecting float, exponent, ambiguous
   precision and noncanonical inputs. Do not round silently.
3. Require a durable server-owned checkout binding (app id, seller,
   `out_trade_no`, Offer, opaque subject and amount) and a **separately
   authenticated active query** record. The caller must query
   `alipay.trade.query`, verify its response signature/certificate and bind
   merchant, transaction, amount, status and environment before constructing
   the active-query record. The record is not valid merely because its type
   can be constructed.
4. Only `TRADE_SUCCESS` matching all three sources can create a canonical
   `payment-succeeded` fact for the existing Commerce journal/outbox path.
   All other states reject. Never award rights on the browser `return_url`.
5. Every signed fixture uses synthetic IDs and a temporary RSA private key
   **not committed** to Git.

## Not yet implemented (must remain disabled for live use)

- Hosting and signed generation of `alipay.trade.page.pay` payment requests;
  generated orders must use collision-safe `out_trade_no` and server-priced
  immutable Offer IDs.
- A duplicate-preserving HTTP `application/x-www-form-urlencoded` parser,
  bounds and canonicalization for actual Alipay notification bodies,
  certificate-mode and key-rotation support.
- Active `alipay.trade.query` signed API client/response verifier,
  retry/reconciliation and durable checkout bindings.
- Asynchronous HTTP notification endpoint, raw payload digest, idempotent
  acknowledgement **after journal commit**, and production edge/issuer
  deployment wiring.
- `alipay.trade.refund`, refund status querying, partial-refund semantics,
  cumulative refund accounting and the full paid/refunded state model.
- Full end-to-end integration, operator runbook and accepted merchant
  credential evidence. The `alipay-confirmed-order` struct is explicitly
  a **trusted-service input** until a real signed query adapter enforces it;
  do not build it from user requests, JSON, test fixtures, or a callback.

## Threat and readiness checks

Verify current merchant/app eligibility and capability matrix (CNY,
one-time website payment, geographic scope, product category, refund fees,
payout and settlement) per ADR-0019 before enabling a live checkout. Payment
receipt, settled balance and bank payout are different financial facts.

Verify signed callback against `app_id`, `seller_id`, `out_trade_no`,
`trade_no`, exact `total_amount`, `trade_status`, and the independently
authenticated order query. Keep payment and Permit signing keys isolated.
Always journal authenticated raw input before the provider acknowledgement;
do not perform slow entitlement signing on the callback thread.

Negative cases: signature tamper, duplicate params, seller/app mismatch,
amount mismatch, replayed `notify_id`, delayed delivery, query timeout,
`WAIT_BUYER_PAY`, partial/full refund, test/production confusion, and
manual operator retry. Do not count source-level tests as a live payment.

### Useful commands once the PR is checked out

```sh
raco pkg install --auto --no-docs --name commerce --link
raco test commerce-test/alipay-test.rkt
raco test -p commerce
raco setup --check-pkg-deps commerce
```

The signed synthetic fixture checks the verification boundary, not actual
Alipay merchant authorization. Issues [#5](https://github.com/turlamai/commerce/issues/5),
[#10](https://github.com/turlamai/commerce/issues/10) and
[#4](https://github.com/turlamai/commerce/issues/4) remain independent
production release gates.
