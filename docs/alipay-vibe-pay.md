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

- Server-controlled \`alipay-order-binding\`: unique merchant order number,
  stable internal subject and Offer, approved application/seller identity,
  and exact CNY fen. Reject zero/negative/ambiguous decimals and amounts
  above the API's published page-pay bound.
- \`make-alipay-page-pay-parameters\`: constructs a signed RSA2
  \`alipay.trade.page.pay\` parameter map for server-side HTTPS submission
  to \`https://openapi.alipay.com/gateway.do\`. Mandatory \`notify_url\`
  and optional \`return_url\` are validated; a return URL is **not proof**.
  Caller supplies the private RSA signing key at the server, never in a
  client/desktop app. Only payment page fields are produced; the application
  must render/redirect appropriately after merchant admission.
- \`alipay-decode-form\`: parse the exact received
  \`application/x-www-form-urlencoded\` POST bytes *once*, with size/field
  bounds; reject duplicate decoded names, malformed percent escapes and
  invalid UTF-8. Do not accept generic "last key wins" middleware output.
- \`verify-alipay-notification\`: build the RSA2 signing representation from
  decoded parameter values sorted by name, excluding \`sign\` and
  \`sign_type\`; verify with the **Alipay public key**, not our own
  merchant public key. Reject algorithm downgrade, bad signature, mismatched
  \`app_id\`, \`seller_id\`, \`out_trade_no\`, CNY total, and unpaid states.
  Return an opaque \`alipay-notification\`, never a \`payment-event\`.
  Use separate official public keys/configuration for sandbox and production.

## Signed active query: implemented protocol proof, not network transport

- \`make-alipay-trade-query-parameters\` signs a bound
  \`alipay.trade.query\` request (including \`sign_type=RSA2\`) for the
  merchant service to submit via the configured HTTPS gateway.
- \`verified-alipay-trade-query->payment-event\` verifies the signed **raw
  JSON response object** from the standard public-key mode, rather than
  parsing and reserializing JSON for signature verification. It then checks
  \`code=10000\`, paid trade status, merchant \`out_trade_no\`, exact CNY
  amount, optional app/seller identity and the notification's trade number
  when one was received. Duplicate critical fields, certificate-mode
  variations, invalid signatures, unpaid and refund-bearing responses
  fail closed. Query-only reconciliation can recover a missing notification.
- A successfully verified active-query result is an ordinary
  \`commerce/payment-event\` with provider \`alipay\`. The caller must
  preserve the same raw signed query response bytes as its journal
  evidence and call \`journal-accept!\` before any outbox projection.
  \`observed-at\` is the worker's actual observation time, **not** a
  fabricated payment date.

**No network transport or webhook server is wired to these helpers yet.**
The buyer/browser must never supply the query response or choose an
arbitrary order. Only a merchant-authenticated HTTPS request to the
official API, correlated to its server-side order binding, is suitable
input. A signed \`notify_url\` notice alone *never* authorizes rights.
The current mode supports only ordinary RSA2 public-key verification;
certificate-mode/third-party delegation needs its own reviewed key and
certificate binding before operation.

## Remaining implementation and release gates

1. Provide a timeout-bounded HTTPS query client for the currently
   authorized merchant app, including response transport/correlation
   handling and bounded reconciliation after lost notifications.
2. Wire \`journal-accept!\`, SQLite projection/outbox and Permit issuance
   to authenticated query results. Build the HTTP \`notify_url\` edge to
   return exact \`success\` only after durable commit; otherwise \`fail\`
   for retries. Keep \`return_url\` informational.
3. Refund and refund-query with stable refund request identities,
   correct *partial* and full refund accounting, conservation tests
   and no silent rights overgrant. A paid trade status alone cannot
   prove there has been no partial refund.
4. Review provider approval and merchant account/product eligibility,
   app/certificate configuration, costs and settlement, HTTPS deployment,
   sandbox credentials, and an **explicitly authorized** low-value
   end-to-end real transaction and recovery rehearsal.
   Commerce's [admission ADR](decisions/0019-provider-admission.md),
   [issue #5](https://github.com/turlamai/commerce/issues/5),
   [issue #10](https://github.com/turlamai/commerce/issues/10), and
   [issue #4](https://github.com/turlamai/commerce/issues/4) remain gates.

## Example: constructing signed page-pay fields

\`\`\`racket
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
\`\`\`

This file is a protocol plan and code handoff. Test keys are generated at
runtime; no payment is charged and no real merchant secrets are stored here.
