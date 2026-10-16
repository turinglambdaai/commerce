# Roadmap

Commerce advances through complete vertical slices. A milestone is not complete
until code, tests, operator evidence, and user documentation agree.

The next implementation handoff is the first unchecked M1 slice. Take only the
immutable raw-event journal and its persistence boundary; do not add projection,
outbox, the Pancake network adapter, Permit signing, or claim delivery in the
same change. Record the chosen persistence contract in an ADR, cover durable
acceptance plus exact/conflicting replay with red/green tests, inspect emitted
rows as evidence, and leave the following unchecked item as the next handoff.

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

- [ ] Immutable raw webhook journal
- [ ] Pancake signature verification with captured test fixtures
- [ ] Active order verification before fulfillment
- [ ] Durable order projection and transactional issuance outbox
- [ ] Offer-to-Permit policy mapping
- [ ] Permit credential issuance and one-time claim delivery
- [ ] Refund and operator replay flow
- [ ] Sandbox end-to-end evidence and runbook

## M2 — Operational baseline

- [ ] Structured redacted logs and correlation ids
- [ ] Health/readiness endpoints and stuck-outbox inspection
- [ ] Encrypted backups with restore rehearsal
- [ ] Key rotation and provider-secret rotation drills
- [ ] Minimal operator CLI: find, replay, reissue, explain
- [ ] Data retention and privacy export/deletion procedures

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

