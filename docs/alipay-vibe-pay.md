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

## Remaining implementation and release gates

1. Wire the existing Commerce HTTP server to the provider's
   `notify_url` POST, fetch the persisted checkout binding from trusted
   storage, authenticate its exact form bytes, perform the active query
   and return **exact `success` only after durable journal acceptance**,
   or `fail` for provider retries. Rehearse lost-notification reconciliation
   and crash recovery, with Permit signing solely in the outbox worker.
2. Add `alipay.trade.refund` and refund-query with stable refund request
   ids, correct partial/full refund accounting, conservation and recovery
   tests. A paid `TRADE_SUCCESS` status does not prove no partial refund.
3. Review merchant/account and software-product admission, SDK/certificate
   mode selection, pricing/fees and settlement, platform policies,
   HTTPS deployment, approved sandbox credentials, and an explicitly
   authorized low-value live transaction and refund/Permit claim canary.
   [ADR-0019](decisions/0019-provider-admission.md),
   [issue #5](https://github.com/turlamai/commerce/issues/5),
   [issue #10](https://github.com/turlamai/commerce/issues/10), and
   [issue #4](https://github.com/turlamai/commerce/issues/4) remain gates.

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
