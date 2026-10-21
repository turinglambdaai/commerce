# ADR-0014: Subscription paid-through semantics

- Status: Accepted
- Date: 2026-10-21

## Context

The journal, projection, lease, issuance, and claim boundaries were built
and proven on one-time purchases. Subscriptions need the same boundaries
to express windows: rights that are paid for until a moment in time,
renewed idempotently, and cancelled at period end without pretending a
revocation happened.

## Decision

The canonical payment event gains `paid-through`: #f for one-time facts,
and — for a subscription payment — the epoch second through which the
provider reports access paid. The moment is derived inside the provider
adapter from provider-native subscription facts (for example the current
period end); Commerce never computes a period itself and never leaks
provider plan objects.

The order projection carries the paid-through window. A subscription
payment advances to the reported window (late events never shrink it) and
emits one renewal intent per new window, idempotency-keyed by the paid-
through epoch — `provider/order/renewal/<paid-through>` — so a
redelivered renewal can never double-extend a window. Redrive, replay,
and lease semantics are unchanged; renewal intents are ordinary outbox
work whose action is `grant`.

The Permit mapping gains the `renew` action and an explicit
`use-expires-at` override:

- a renewal is a complete successor revision naming the previous revision
  with `use_expires_at` equal to the new paid-through — rights lapse when
  the paid window lapses;
- a withdrawal for a subscription order expires its successor at the
  paid-through moment (cancellation at period end) instead of at issuance;
- a one-time withdrawal keeps expiring at issuance.

The worker distinguishes renewals from second one-time purchases by the
order projection: a grant intent over an existing lineage with a
paid-through order is a renewal; without one it is deterministic operator
work (`entitlement-lineage-conflict`). The transactional writer allows
grant successors over an existing lineage for exactly this reason; the
worker still refuses second one-time grants before signing. Plan changes
are represented as the next revision of the same lineage under the
offer's pinned policy; proration is computed at checkout, and Commerce
records the resulting payment facts — provider plan objects never enter
the projection.

SQLite schema v5 adds the nullable `paid_through` column to the journal
snapshot and the order projection; v1-v4 databases migrate in place.

## Consequences

- Subscriptions ride the same journal/outbox/lease/lineage machinery with
  no second workflow: renewal storms are just outbox work.
- The renewal window is provider-reported evidence, auditable in the
  journal like any other fact.
- Cancellation wording stays honest: access ends when the paid window
  ends; an offline credential is not otherwise revoked.
- Activation-lease refresh remains a product-level choice (Permit
  activation semantics) for products needing timely enforcement inside a
  window.
