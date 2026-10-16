# Family integration

The canonical five-repository graph, ownership table, release order, and trust
boundaries live in Keel's
[family architecture](https://github.com/turinglambdaai/keel/blob/main/docs/family-architecture.md).
This document defines only Commerce's local edges; if the two disagree, update
the canonical document and this summary in the same coordinated change.

## Commerce boundary

Commerce owns provider authentication adapters, the immutable payment-event
journal, commercial projections, provider-to-Offer mapping, rights intents,
issuance workflow, claim delivery, reconciliation, and operator audit.

Commerce does not own:

- money movement, tax calculation, or Merchant of Record obligations;
- login, password recovery, or the source of customer identity;
- Permit credential schemas, trust rules, or client authorization;
- application lifecycle, UI hosting, packaging, or updates;
- Keel application values or the RVT1/GLZ1 transports.

## Dependency direction

```text
Product ──> Rivet or Glaze ──> Keel
   ├──────> Permit
   └──────> Commerce client (optional) ──> Commerce service
                                               ├── provider adapters
                                               └── issuer adapter ──> permit/issuer
```

The default `commerce` facade and pure core do not import Permit. Only the
explicit issuer adapter may consume `permit/issuer`, and Permit never imports
Commerce. Rivet, Glaze, and Keel never import Commerce. An operator UI may be a
separate Glaze product without making the headless Commerce service depend on
Glaze.

## Product composition

A free product needs neither Permit nor Commerce. A manually fulfilled or
fully offline paid product may use Permit without Commerce. An online-sale
product adds Commerce for checkout, payment evidence, issuance, and claim
delivery, then authorizes locally only from the resulting verified Permit
credential.

The product or an identity service supplies or establishes the opaque stable
subject id. Email and provider customer ids are mappings, not authorization
identities. Checkout redirects, claim tokens, and Commerce API responses are
workflow evidence, never permission to unlock a feature.

## Change flow

- A new signed right or trust meaning starts in Permit, is released, then is
  adopted by the Commerce issuer adapter and products.
- A provider-specific fact stays in its adapter until a durable
  provider-neutral semantic is demonstrated.
- A Commerce event, projection, Offer, rights-intent, issuance, or delivery
  change starts here and flows to Commerce clients and affected products.
- A product UI or feature-policy change stays in the product unless repeated
  use proves a narrower reusable contract.

Cross-repository changes are sequenced through released packages and recorded
in a GitHub issue. Do not copy source or land speculative matching APIs in
multiple repositories at once.

