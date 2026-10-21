# ADR-0015: HTTP webhook edge

- Status: Accepted
- Date: 2026-10-22

## Context

Every prior boundary proved its invariants headlessly. The remaining
server gap was the one customers point a provider at: an HTTP endpoint
that receives Pancake webhooks. The risk of an HTTP edge is that it
becomes a second brain — parsing, mapping, or issuance logic leaking
into the request path.

## Decision

`commerce/server` is a thin shell with two layers:

- `handle-webhook-post` is the product: exact request bytes and the
  signature header in, HTTP status and JSON out. The order is fixed:
  authenticate the exact bytes, resolve the durable checkout binding by
  the webhook's order id, actively verify the one-time order against the
  provider-native binding shape (the server owns that adaptation),
  journal the canonical event. The journal's idempotence decides the
  acknowledgement — an exact redelivery is 200 `replayed`, a conflicting
  replay is 409 — and no issuance, signing, or delivery ever happens in
  the request path.
- `serve-webhook-endpoint` binds one route on a port and returns a
  shutdown procedure. TLS termination, request limits, and deployment
  hardening stay outside this boundary.

Schema v6 adds the append-only `commerce_checkout_binding` table: the
merchant external reference maps to one provider product, stable Offer,
stable subject, and exact money; triggers reject mutation. Bindings are
created at checkout time (`storage-create-checkout-binding!`), and the
webhook path fails closed with 404 when a webhook references an order
with no durable expectation.

Status mapping is deliberate and total: authentication-family failures
(401) create no evidence; unknown checkout (404), conflicting replay
(409), and semantic mismatches between webhook, active order, and
expectation (422) are typed commerce codes; provider unavailability is
503 so the provider retries.

## Consequences

- The M-grade roadmap has no remaining ungated functional slice: one
  verified payment can now flow from a real HTTP webhook to a claimable
  credential, each stage durably evidenced.
- Deployment still owes TLS, rate limiting, logging sinks, and process
  supervision; the edge deliberately does none of these.
- A production merchant client's transport defaults are live HTTP; tests
  inject deterministic transports as before.
