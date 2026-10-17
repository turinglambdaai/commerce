# Roadmap

Commerce advances through complete vertical slices. A milestone is not complete
until code, tests, operator evidence, and user documentation agree.

The next implementation handoff is the first unchecked M1 slice. Take only the
Offer-to-Permit policy mapping: define the validated policy input and complete
rights snapshot requested from Permit for a one-time grant or withdrawal. Do
not call a signer, mutate outbox workflow state, deliver claims, add an HTTP
listener, or introduce subscription policy in the same change. Record policy
versioning, unknown/deleted Offer behavior, entitlement lineage inputs, and
typed failures before adding the adapter.

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

