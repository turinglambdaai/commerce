# AGENTS.md

## Scope

Commerce is the provider-neutral commercial management plane for the
TuringLambdaAI product family. It accepts authenticated payment facts, projects
minimal commercial state, and emits auditable rights intents that an explicit
Permit issuer integration may turn into signed credentials.

Commerce is not a payment processor, merchant of record, tax engine, account
system, CRM, or client-side licence verifier. Read `docs/architecture.md` before
changing code. Treat `docs/provider-contract.md`, `docs/security.md`, and
`docs/family-integration.md` as normative local boundaries. The canonical
five-repository graph and release order live in Keel's
[`docs/family-architecture.md`](https://github.com/turinglambdaai/keel/blob/main/docs/family-architecture.md).
Read `ROADMAP.md` and take only one bounded milestone slice at a time.

## Dependency direction

```text
product -> Rivet or Glaze
product -> Permit
product -> Commerce client (optional)

Commerce service -> provider adapters
Commerce service -> Permit issuer

Rivet / Glaze / Keel -X-> Commerce
Permit               -X-> Commerce
```

Do not add Commerce dependencies to Rivet, Glaze, Keel, or Permit. Do not move
checkout, order, subscription, customer, payment, or account policy into those
libraries to make an integration more convenient. The explicit Commerce issuer
adapter may import `permit/issuer`; the default `commerce` facade and pure core
may not. A future operator UI may be a separate Glaze application, but the
headless service core may not depend on a UI framework.

## Invariants

- Money is an exact non-negative integer in the currency's minor unit. No
  binary floating point enters the domain model.
- A provider event is accepted only after provider-native authentication and
  semantic validation. The default `commerce` facade cannot construct one.
- `(provider, event-id)` is the delivery idempotency key. Replaying the exact
  same event is a no-op; replaying the same key with different content fails
  closed and is operator-visible.
- `(provider, order-id)` identifies one provider order. Offer, subject, and
  amount cannot silently change across its events.
- Webhook handlers persist authenticated raw input before deriving projections.
  Production issuance is an outbox consumer, never an inline webhook side
  effect.
- Provider state is payment evidence, not product authorization. Only a valid
  signed Permit credential authorizes a product.
- Refund and chargeback do not magically revoke an offline credential. Policy
  must explicitly choose replacement credentials, activation leases, signed
  revocation state, or accepted commercial risk.
- Payment-provider secrets, Permit private keys, update-signing keys, and OS
  publisher credentials are separate trust domains with separate rotation.
- Customer email is display/contact data, never the stable authorization key.
- Login and account recovery belong to the product or identity service.
  Commerce consumes an opaque stable subject id and never treats a provider
  customer id or claim token as local authorization evidence.
- Raw provider payloads and personal data are minimized, access-controlled,
  retained for a documented period, and never written to ordinary logs.

## Public API tiers

- `(require commerce)` is pure and safe for deterministic domain work.
- `(require commerce/provider)` is server-side integration surface. It owns the
  only public constructor for verified canonical payment events.
- `(require commerce/journal)` defines durable acceptance semantics;
  `(require commerce/journal/sqlite)` selects the first filesystem backend.
- `(require commerce/pancake)` authenticates exact Pancake webhook bytes and
  returns provider-native evidence; it does not construct canonical events.
- Network listeners, persistence, provider SDKs, and Permit issuer adapters use
  explicit modules and are never re-exported from `commerce`.
- Implementation-only helpers belong under `commerce/private/`.

## Change protocol

1. State the invariant and failure mode in the relevant canonical document or
   an ADR under `docs/decisions/`.
2. Add characterization or red tests before changing behavior.
3. Change one boundary at a time.
4. Run the focused tests, full package tests, package dependency check, and
   documentation build.
5. Update English and Chinese entry documentation when the user path changes.
6. Record an honest changelog entry; do not claim production readiness from
   mocks or unit tests.

## Required verification

```bash
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/journal/sqlite.rkt commerce/pancake.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
raco scribble --htmls --dest <temporary-directory> \
  commerce-doc/scribblings/commerce.scrbl
```

Every event-handling bug receives red/green tests covering all affected entry
points. For persistence or serialization defects, inspect emitted artifacts or
database rows rather than relying only on source matching.

## Handoff standard

Leave the repository understandable without chat history. A completed change
contains code, tests, the canonical documentation update, operational evidence,
and no uncommitted files. Commit and push all completed work; `main` is the
cross-device source of truth.

