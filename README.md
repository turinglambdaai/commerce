# Commerce

**One commercial truth for every product — payment events in, signed product rights out.**

[![CI](https://github.com/turinglambdaai/commerce/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/commerce/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE) ![Stage](https://img.shields.io/badge/stage-architecture%20foundation-C15F3C)

**English** · [中文](README.zh-CN.md)

Commerce is the provider-neutral commercial management plane for independent
software. It gives every product one place to create checkout sessions, accept
and audit payment events, project orders and subscriptions, and turn commercial
outcomes into signed [Permit](https://github.com/turinglambdaai/permit) rights.

Commerce is not a payment processor, merchant of record, tax engine, CRM, or
DRM system. Pancake, ZPAY, app stores, and future providers remain responsible
for moving money. Permit remains responsible for signed, locally verifiable
rights. Commerce owns the durable orchestration between them.

**Provider-neutral. Event-driven. Rights-first.**

## Quick start

The first release is an architecture foundation. It already provides the pure
event core, replay/conflict protection, order projections, rights intents, a
provider boundary, tests, and one runnable purchase walkthrough.

```bash
raco pkg install --auto --name commerce \
  https://github.com/turinglambdaai/commerce.git

racket examples/first-purchase.rkt
```

Expected result:

```text
order ord_demo_001: paid
rights intent: grant taskly-pro-lifetime to customer-demo
duplicate webhook: ignored
```

Continue with **[Getting started](docs/getting-started.md)**. The
[documentation map](docs/README.md) identifies the canonical guide for every
architectural and operational question.

## Why Commerce?

A product can integrate one checkout in an afternoon. A product family cannot
safely repeat payment verification, retries, refunds, subscription renewal,
credential recovery, and licence issuance in every application.

Commerce creates one durable boundary:

- **Products speak offers and rights** — they never embed provider API keys or
  signing keys.
- **Providers speak payments** — each adapter verifies its native protocol and
  emits the same small canonical event vocabulary.
- **Permit speaks authorization** — Commerce requests complete signed rights
  snapshots; applications verify them locally.
- **Every transition is auditable** — raw events are retained, duplicate
  delivery is harmless, conflicting replay fails closed, and issuance is an
  explicit outbox step rather than a webhook side effect.

## Where it fits

```text
                         Product
                    /       |       \
              Rivet/Glaze  Permit  Commerce client
                    UI      verify       |
                                         v
                                 Commerce service
                              /          |          \
                       Pancake         ZPAY       app stores
                              \          |          /
                               verified payment events
                                         |
                                  rights intent
                                         |
                                  Permit issuer
                                         |
                              signed Permit credential
```

The dependency direction is deliberate:

```text
product  -> Rivet or Glaze
product  -> Permit
product  -> Commerce client       (only when online commerce is wanted)

Commerce service -> payment providers
Commerce service -> Permit issuer

Rivet / Glaze / Keel -X-> Commerce
Permit               -X-> Commerce
```

See [Architecture](docs/architecture.md) and
[Family integration](docs/family-integration.md) for the local ownership rules;
the [family architecture](https://github.com/turinglambdaai/keel/blob/main/docs/family-architecture.md)
is the canonical five-repository contract.

## Core vocabulary

| Concept | Meaning |
| --- | --- |
| Product | Stable software identity, such as `taskly` |
| Offer | Something a customer may buy, such as `taskly-pro-lifetime` |
| Provider mapping | The Pancake/ZPAY/store identifiers that implement an offer |
| Payment event | A verified, immutable fact received from a provider |
| Order projection | Commerce's minimal local view of commercial state |
| Rights intent | An auditable request to grant, renew, replace, or withdraw rights |
| Issuance | The eventual signed Permit credential and its delivery state |

Commerce does not clone a provider's entire product catalog or customer
database. Provider objects remain the source of payment facts; Commerce stores
only the identifiers and projections required for deterministic orchestration.

## Public modules

```racket
(require commerce)           ; pure domain model and state transitions
(require commerce/provider)  ; server-side provider adapter boundary
```

The default `commerce` facade does not expose provider secrets, raw webhook
acceptance, network listeners, databases, or Permit signing. Those capabilities
belong to explicit server-side modules as they are implemented.

## Current status

Implemented now:

- exact integer minor-unit money values and stable offer identities;
- verified canonical payment events;
- provider event idempotency and conflicting-replay rejection;
- order projections that tolerate refund-before-payment delivery;
- deterministic `grant` and `withdraw` rights intents;
- a provider adapter contract and mock walkthrough;
- bilingual entry documentation, normative architecture, and CI gates.

Not implemented yet:

- Pancake or ZPAY network adapters;
- durable SQL storage and webhook HTTP endpoints;
- Permit issuer integration and credential delivery;
- subscriptions, seats, credential-claim portal, or an operator UI;
- production deployment or a claim of payment-provider certification.

The next bounded slice is the Pancake one-time-purchase path described in
[ROADMAP.md](ROADMAP.md). Honest gaps are kept visible so architecture does not
get mistaken for production readiness.

## Development

```bash
raco pkg install --auto --no-docs --name commerce .
raco make commerce/main.rkt commerce/provider.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

Before changing a boundary, read [AGENTS.md](AGENTS.md) and
[Architecture](docs/architecture.md). Every public API change ships with tests,
English and Chinese entry documentation where affected, and the corresponding
normative document update.

## License

Apache-2.0. See [LICENSE](LICENSE).

