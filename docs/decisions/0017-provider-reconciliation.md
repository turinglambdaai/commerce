# ADR-0017: Provider reconciliation

- Status: Accepted
- Date: 2026-10-22

## Context

Operations requires a scheduled comparison of provider order facts with
local projections over a bounded moving window, ingesting missing facts
through the same adapter path and reporting unexplained differences
without silently rewriting history.

## Decision

`commerce/pancake` gains `read-pancake-onetime-order`: a signed,
bounded, read-only merchant read that returns the minimal provider facts
(status, test mode, payment id and status, currency, exact minor units)
without constructing a canonical event.

`commerce/reconcile` compares those facts with the order projection and
reports typed differences: `missing-webhook` when the provider says an
order is paid but Commerce has no paid projection, `provider-disagrees`
when the projections say paid but the provider no longer shows a
succeeded payment, `provider-order-not-found` when the provider no
longer knows the order, and `provider-read-refused` for typed read
failures that are operator work. Retryable transport unavailability
yields no difference — the next pass re-reads.

Reconciliation never mutates journal, projection, or outbox state. A
difference is an operator signal; the missing fact still enters through
the webhook/journal path, so commercial truth keeps one ingress.

## Consequences

- "I paid but Pro is not active" has a proactive answer: the reconciler
  finds the divergence before the customer does.
- The bounded, read-only shape keeps reconciliation safe to schedule.
- Provider order reads still count against provider rate limits; the
  operator chooses the window.
