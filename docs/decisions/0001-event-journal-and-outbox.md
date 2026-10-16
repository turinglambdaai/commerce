# ADR-0001: Immutable event journal and transactional outbox

Status: accepted, 2026-10-16

## Context

Payment providers retry and reorder notifications. Credential signing, email,
and customer delivery can fail after a provider expects a fast acknowledgement.
Executing fulfillment inline cannot make these failures atomic.

## Decision

Commerce stores each authenticated raw provider event immutably under
`(provider, event-id)`. Projection changes and issuance-outbox insertion occur
in one local database transaction. A separate idempotent worker performs Permit
issuance and delivery.

Exact event replay is a no-op. The same event key with different authenticated
content is a security/operations conflict and fails closed.

## Consequences

- Webhook latency is independent of signing and delivery.
- Crashes can replay journal/outbox state without double granting.
- Current projections can be rebuilt and audited.
- The service must operate a journal, outbox worker, reconciliation, retention,
  and quarantine path instead of one simple callback handler.

