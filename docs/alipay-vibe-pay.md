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

## Not yet implemented: NO issuance on callback alone

Alipay's official web integration explicitly requires querying actual
trade status when the browser return or callback is missing. A signed
\`notify_url\` response still needs production order lookup validation and
durable journal acceptance. The current adapter intentionally has **no**
function that can convert a callback into verified Commerce payment facts.

Next slices, in order:

1. Production-safe \`alipay.trade.query\` transport with RSA2 request
   signing, signed response verification for the configured Alipay key/
   certificate mode, status/amount/order/app/seller/trade-number matching,
   typed timeout/refusal and bounded reconciliation. Use a testable injected
   transport and no hidden retry after unknown payment outcome.
2. Integrate authenticated query results with
   \`make-verified-payment-event\`, \`journal-accept!\`, projection, outbox
   and Permit claim delivery. The journal must preserve original bytes and
   mark success only **after** its transaction commits.
3. Refund/refund-query with stable refund request identifiers, money
   conservation and separately modeled partial/full refund facts. An
   Alipay \`TRADE_SUCCESS\` state alone does **not** prove no refund.
4. Server HTTP \`notify_url\` endpoint: return exact \`success\` only
   after durable acceptance; otherwise \`fail\` for provider retries.
   Keep untrusted browser \`return_url\` informational.
5. Approved merchant account, current application contract, fees/settlement,
   test credentials, real sandbox and explicitly authorized low-value canary.
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
