# ADR-0013: Structured, redacted-by-construction logs

- Status: Accepted
- Date: 2026-10-21

## Context

Commerce already forbids raw payloads and personal data in ordinary logs.
"Never" enforced by review is not a boundary; every future call site could
interpolate a webhook body or a claim token into a format string. M2's
observability baseline needs event records that are structured from birth
and cannot carry secrets.

## Decision

`commerce/log` defines the one logging path: `log-commerce-event!` emits a
typed `commerce-log-event` (level, code, correlation, fields, timestamp)
onto the `commerce` logger topic. Redaction is enforced by validation, not
convention:

- correlation keys are a closed whitelist (provider, event-id, order-id,
  subject-id, offer-id, idempotency-key, outbox-id, entitlement-id,
  credential-id, claim-id, revision, policy-id, sequence) with scalar
  values only;
- field values are whitelisted scalars: strings, exact integers,
  booleans, and workflow-state symbols;
- bytes, hashes of unlisted keys, and unlisted symbols raise
  argument errors before anything is emitted.

The public surfaces instrument their own transitions — journal acceptance
and conflict, projection and blocking, lease claim/complete/release,
redrive, and claim fulfillment or refusal — so any backend benefits and
the worker stays thin. Debug-level events (exact replays, idle polling)
disappear at info level. Transport formatting and shipping are deployment
concerns, not this boundary.

## Consequences

- A reviewer can grep one module to see every loggable field.
- Correlation ids match the operational search requirements: provider +
  event id, provider + order id, entitlement and revision, outbox work,
  and claims.
- Server deployments still owe JSON-line formatting, levels, and shipping;
  the HTTP edge is a future slice.
