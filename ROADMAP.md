# Roadmap

Commerce advances through complete vertical slices. A milestone is not complete
until code, tests, operator evidence, and user documentation agree.

M1-M3 and the operational baseline are complete, including the HTTP
edge, claim portal, operator audit with reissue, and provider
reconciliation. Every remaining gap is gated on something outside this
repository: live sandbox credentials, provider API contracts for
checkout creation and additional channels (ZPAY, app stores), and
delivery transports. Those open on measured demand; keep the honest-gap
lists in both READMEs current until then.

## M0 — Architecture foundation

- [x] Family dependency and ownership boundary
- [x] Stable product/offer vocabulary
- [x] Exact money representation
- [x] Verified canonical payment events
- [x] Duplicate and conflicting replay behavior
- [x] Minimal order projection and rights intents
- [x] Provider adapter contract and mock walkthrough
- [x] Bilingual onboarding and CI gates

## M1 — Pancake one-time purchase

- [x] Immutable raw webhook journal
- [x] Pancake signature verification with captured protocol fixtures
- [x] Active order verification before fulfillment
- [x] Durable order projection and transactional issuance outbox
- [x] Offer-to-Permit policy mapping
- [x] Permit credential issuance and one-time claim delivery
- [x] Refund and operator replay flow
- [x] Sandbox end-to-end evidence and runbook

## M2 — Operational baseline

- [x] Structured redacted logs and correlation ids
- [x] Health/readiness endpoints and stuck-outbox inspection
- [x] Encrypted backups with restore rehearsal
- [x] Key rotation and provider-secret rotation drills
- [x] Minimal operator CLI: find, replay, reissue, explain
- [x] Data retention and privacy export/deletion procedures

## M3 — Subscriptions

- [x] Paid-through projection and renewal revisions
- [x] Cancellation-at-period-end semantics
- [x] Failed-payment grace policy
- [x] Activation lease refresh where timely enforcement is required
- [x] Upgrade/downgrade proration represented without provider leakage

Grace is represented by the provider-reported paid-through window (grace
lives inside the window the provider grants during dunning); activation
lease refresh is a product-level choice under Permit's activation
semantics; proration is computed at checkout and enters Commerce as
ordinary payment facts. Additional channels begin only after measured
product demand, per M4.

## M4 — Additional channels

- [ ] ZPAY one-time purchase adapter
- [ ] Apple App Store receipt exchange
- [ ] Google Play receipt exchange
- [ ] Microsoft Store receipt exchange

Additional channels begin only after measured product demand. Capability
differences remain explicit; Commerce will not pretend every provider supports
subscriptions, partial refunds, or the same customer identity model.

