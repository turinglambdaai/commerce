# Roadmap

Commerce advances through complete vertical slices. A milestone is not complete
until code, tests, operator evidence, and user documentation agree.

M1 and M2 are complete. The next handoff opens M3 subscriptions: extend
the paid-through projection with subscription order semantics, then renewal
revisions, cancellation-at-period-end, and failed-payment grace through the
same journal/outbox/lease boundary. One bounded slice at a time; keep the
honest-gap lists in both READMEs current.

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

- [ ] Paid-through projection and renewal revisions
- [ ] Cancellation-at-period-end semantics
- [ ] Failed-payment grace policy
- [ ] Activation lease refresh where timely enforcement is required
- [ ] Upgrade/downgrade proration represented without provider leakage

## M4 — Additional channels

- [ ] ZPAY one-time purchase adapter
- [ ] Apple App Store receipt exchange
- [ ] Google Play receipt exchange
- [ ] Microsoft Store receipt exchange

Additional channels begin only after measured product demand. Capability
differences remain explicit; Commerce will not pretend every provider supports
subscriptions, partial refunds, or the same customer identity model.

