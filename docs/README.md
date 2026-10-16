# Documentation map

Commerce keeps one canonical document for each durable decision. README files
teach the first path; normative documents define behavior; runbooks explain
operations. Do not duplicate a rule across several guides.

## Start here

- [Getting started](getting-started.md) · [中文](getting-started.zh-CN.md) —
  install, run the walkthrough, and understand the first edit points.
- [Concepts](concepts.md) — Product, Offer, payment event, projection, rights
  intent, issuance, and claim.
- [Architecture](architecture.md) — ownership, dependency direction, data flow,
  process boundaries, and consistency model.

## Integration contracts

- [Provider contract](provider-contract.md) — what every Pancake, ZPAY, or
  store adapter must prove before emitting a canonical event.
- [Permit integration](permit-integration.md) — how rights intents become
  complete signed credential revisions.
- [Family integration](family-integration.md) — Commerce's local edges to
  Rivet, Glaze, Keel, Permit, products, and identity systems; it links to the
  canonical five-repository architecture.

## Production work

- [Security](security.md) — trust domains, webhook authentication, keys,
  personal data, and failure behavior.
- [Operations](operations.md) — replay, stuck work, refunds, reconciliation,
  backup/restore, and observability requirements.
- [Roadmap](../ROADMAP.md) — bounded implementation milestones.

## Decisions

- [ADR-0001: Immutable event journal and transactional outbox](decisions/0001-event-journal-and-outbox.md)
- [ADR-0002: Pure default facade and explicit server capabilities](decisions/0002-public-api-tiers.md)
- [ADR-0003: SQLite event journal v1](decisions/0003-sqlite-event-journal-v1.md)
- [ADR-0004: Pancake webhook authentication boundary](decisions/0004-pancake-webhook-authentication.md)
- [ADR-0005: Pancake active one-time order verification](decisions/0005-pancake-active-order-verification.md)

## Source entry points

| Path | Responsibility |
| --- | --- |
| `commerce/main.rkt` | safe default facade |
| `commerce/core.rkt` | deterministic payment-event projections |
| `commerce/provider.rkt` | explicit server-side provider boundary |
| `commerce/journal.rkt` | durable event-acceptance protocol |
| `commerce/journal/sqlite.rkt` | SQLite raw-event journal backend |
| `commerce/pancake.rkt` | Pancake webhook authentication and active order proof |
| `commerce/private/` | implementation-only model and validation |
| `commerce-test/` | behavior and invariant tests |
| `examples/` | copyable newcomer paths |

