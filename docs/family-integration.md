# Family integration

Commerce joins the TuringLambdaAI family as a sibling commercial management
component. It is not the new root of the family dependency graph.

## Responsibilities

| Component | Owns | Explicitly does not own |
| --- | --- | --- |
| Keel | shared application values, canonical encoding, lifecycle/schema vocabulary | UI, transport, payments, product rights |
| Rivet | first-party native hosts, RVT1, embedding, packaging, updates | accounts, checkout, pricing, entitlements |
| Glaze | WebView application runtime, GLZ1, capabilities, packaging, updates | accounts, checkout, pricing, entitlements |
| Permit | signed rights, trust, verification, trials, activations, policy evaluation | checkout, invoices, tax, payment accounts, hosted management |
| Commerce | provider orchestration, payment journal, commercial projections, rights intents, issuance workflow | payment acquiring, tax/MoR promises, client authorization, UI frameworks |

## Product composition

A desktop product normally depends on Rivet or Glaze and Permit. It adds the
Commerce client only when it needs checkout creation, credential claiming, or
managed refresh. A fully offline/manual-sale product may use Permit without
Commerce.

Commerce may later use Glaze for an operator console, but that UI dependency
does not change domain ownership. Commerce's server core must remain usable
without launching a desktop host.

## Shared contracts

- Keel changes originate in Keel and flow into Rivet/Glaze.
- Permit wire/trust changes originate in Permit and flow into Commerce/products.
- Commerce event/offer/issuance changes originate here and flow into Commerce
  clients and product upgrade flows.
- Payment-provider API changes stay in their adapter until a provider-neutral
  semantic is demonstrated.

Documents link to the normative owner instead of copying its complete rules.

