# Alipay Vibe Pay basic collection: Racket integration boundary

**Status: first protocol slice implemented; NOT production-admitted or live-payable.**
The Vibe Pay *basic web collection* path uses ordinary Alipay RSA2 gateway
methods; it is not the Alipay-managed product/order/rights "smart suite."
Commerce remains responsible for offers, stable subjects, durable journal,
outbox and Permit issuance. Nothing in this repository opens a merchant account
or implies eligibility for personal software/AI services.

## Official contract (checked 2026-10-30)

- [Vibe Pay product](https://aipay.alipay.com/products/vibe-pay)
- [Web integration](https://aipay.alipay.com/docs/vibe-pay/ai-web-app-payment-qianyi/ai-web-app-payment-integration-guide.html)
- [Page pay API](https://aipay.alipay.com/docs/vibe-pay/ai-web-app-payment-qianyi/api-list/alipay-trade-page-pay.html)
- [Active query](https://aipay.alipay.com/docs/vibe-pay/ai-web-app-payment-qianyi/api-list/alipay-trade-query.html)
- [Async notification and signature](https://aipay.alipay.com/docs/vibe-pay/ai-web-app-payment-qianyi/api-list/async-notify-verify.html)

## Implemented in commerce/alipay

- Server-controlled `alipay-order-binding`: unique merchant order number,
  stable internal subject and Offer, approved application/seller identity,
  and exact CNY fen. Reject zero/negative/ambiguous decimals and amounts
  above the API's published page-pay bound.
- `make-alipay-page-pay-parameters`: constructs a signed RSA2
  `alipay.trade.page.pay` parameter map for server-side HTTPS submission
  to `https://openapi.alipay.com/gateway.do`. Mandatory `notify_url`
  and optional `return_url` are validated; a return URL is **not proof**.
  Caller supplies the private RSA signing key at the server, never in a
  client/desktop app. Only payment page fields are produced; the application
  must render/redirect appropriately after merchant admission.
- `alipay-decode-form`: parse the exact received
  `application/x-www-form-urlencoded` POST bytes *once*, with size/field
  bounds; reject duplicate decoded names, malformed percent escapes and
  invalid UTF-8. Do not accept generic "last key wins" middleware output.
- `verify-alipay-notification`: build the RSA2 signing representation from
  decoded parameter values sorted by name, excluding `sign` and
  `sign_type`; verify with the **Alipay public key**, not our own
  merchant public key. Reject algorithm downgrade, bad signature, mismatched
  `app_id`, `seller_id`, `out_trade_no`, CNY total, and unpaid states.
  Return an opaque `alipay-notification`, never a `payment-event`.
  Use separate official public keys/configuration for sandbox and production.

## Signed active query, HTTPS client, and journal integration

- `make-alipay-trade-query-parameters` signs a bound
  `alipay.trade.query` request with RSA2 and the **request-specific**
  `sign_type` parameter.
- `verified-alipay-trade-query->payment-event` verifies the raw signed
  Alipay JSON response value, not a parsed/re-encoded approximation. It
  requires `code=10000`, matching `out_trade_no`, CNY total, optional
  app/seller identity, a successful trade state, and matching
  notification trade number when the notification was received.
  Duplicate critical keys, unsigned/malformed responses, certificate
  mode, unknown status and refund-bearing results fail closed.
- `commerce/alipay/client` provides a bounded merchant-only TLS client.
  `alipay-query-payment` uses fixed official sandbox/production gateways,
  explicit timeouts, no redirects, one attempt, bounded response bytes,
  server-created checkout bindings, and the merchant's RSA2 private key.
  Browser parameters never select a new order. A lost notification may
  be recovered through a separately triggered authenticated query.
- `alipay-query-and-journal!` passes the same signed response bytes and
  the independently verified canonical payment fact to
  `journal-accept!`. The transaction must commit before any success
  acknowledgement; the existing Commerce projector/outbox/issuer remain
  asynchronous. There is no direct Permit signing from a callback.

**The HTTP `notify_url` handler and product checkout UI are not yet wired.**
The Racket library includes a transport-capable server path, not a public
hosted payment service. An HTTP return URL or signed callback alone
does not prove a completed transaction. The current verifier supports
ordinary RSA2 public-key mode, not provider certificate-mode credentials.

## HTTP notify_url: implemented as a separate Commerce listener

`commerce/alipay/server` provides `make-alipay-webhook-endpoint`,
`handle-alipay-webhook-post` and `serve-alipay-webhook-endpoint`.
The handler accepts **raw POST bytes**, resolves a previously committed
`storage-checkout-binding-ref` by the untrusted merchant order number,
requires the stored provider/CNY/exponent/Offer/subject identity, then
verifies the RSA2 notice using the configured merchant client's Alipay
public key. It performs an active signed `alipay.trade.query` via the
merchant-only HTTPS client, commits the exact query-response bytes and
verified canonical payment event to Commerce's journal, and replies with
**only** `success` for `accepted`/`replayed`. All unknown/malformed/
unverifiable paths reply `fail`. No Permit issuer runs synchronously.

This is a **separate** Racket web-server listener on `/webhooks/alipay`,
rather than a silent change to the existing Pancake listener. Operators
must route HTTPS through a vetted reverse proxy, configure the correct
host timezone for the Alipay query timestamp, persist a trusted checkout
binding before presenting payment, and keep the issuer/outbox workers
separate. Do not expose a development listener on the public network.
The RSA2 public-key mode alone is supported: Alipay certificate-mode or
delegated applications require another reviewed implementation.

## Remaining implementation and release gates

1. Rehearse a complete **approved sandbox** instance end-to-end:
   saved binding, hosted pay redirect, signed notify, active query,
   durable acknowledgement, projection/outbox, offline Permit claim,
   lost-notify reconciliation and backup/restore. Add real service
   configuration, key rotation, concurrency and HTTP integration tests.
   A green fake-transport suite is not sandbox evidence.
2. Design and implement refund and refund-query flows with stable
   refund request identities, correct partial/full-refund accounting,
   conservation and recovery. Current code **refuses** refund-bearing
   notifications and queries rather than misclassifying them as purchases.
   Commerce's current core models refunded orders as a boolean; partial
   refunds require a reviewed durable model extension before production.
3. Complete merchant/account/software-category admission, live fees and
   settlement, app/certificate mode, sandbox/live key scoping, HTTPS
   deployment and an explicitly authorized first real low-value payment
   and refund/claim canary. See
   [ADR-0019](decisions/0019-provider-admission.md),
   [issue #5](https://github.com/turlamai/commerce/issues/5),
   [issue #10](https://github.com/turlamai/commerce/issues/10), and
   [issue #4](https://github.com/turlamai/commerce/issues/4).

## Example: constructing signed page-pay fields

```racket
#lang racket/base
(require commerce commerce/alipay)

(define binding
  (make-alipay-order-binding
   "order_001" "taskly-pro-lifetime" "subject-001"
   (money "CNY" 1990) "APP_ID_FROM_APPROVED_MERCHANT" "SELLER_ID"))

;; Example only: load a protected private PEM in the issuer/checkout service,
;; never in a desktop installer or a repository.
(define request-fields
  (make-alipay-page-pay-parameters
   binding merchant-private-pem "Taskly Pro"
   "2026-10-30 10:00:00"
   "https://your-service.example/alipay/notify"
   #:return-url "https://your-service.example/purchases/return"))

;; Submit these fields to alipay-gateway-url only after account admission.
;; The notify result needs signature verification AND active order query.
```

This file is a protocol plan and code handoff. Test keys are generated at
runtime; no payment is charged and no real merchant secrets are stored here.
