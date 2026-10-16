# Operations

Commerce must remain explainable when a customer says, “I paid, but Pro is not
active.” The operator path is a first-class product surface.

## Required correlation

Every flow must be searchable by:

- internal correlation id;
- provider + event id;
- provider + order id;
- internal subject id;
- offer id;
- entitlement id and revision;
- issuance and claim id.

Search results show redacted summaries and links between records, never raw
secrets or complete personal/payment payloads by default.

## Replay

Replay always reuses the immutable journal entry through the normal projection
path. Operators do not edit a projection row to “fix” an order. An exact replay
is safe; a changed payload under the same event id is quarantined.

## Reconciliation

Scheduled reconciliation compares provider order facts with local projections
for a bounded moving window. It ingests missing facts through the same adapter
path and reports unexplained differences. It never silently rewrites journal
history.

## Journal evidence

The SQLite journal uses application id `COMM` and schema version 1. Operational
inspection should select identifiers and status metadata, not `raw_payload`:

```sql
SELECT sequence, provider, event_id, event_kind, order_id, received_at
FROM commerce_event_journal
ORDER BY sequence;
```

Rows reject ordinary `UPDATE` and `DELETE`. Repair or future retention requires
a versioned, audited database operation; disabling the triggers for routine
customer support is not a supported workflow.

## Stuck work

The operator surface distinguishes:

- event accepted but projection blocked;
- projection complete but issuance pending;
- credential signed but delivery unclaimed;
- retry scheduled versus terminal operator action required.

Every retry is bounded and observable. Poison work moves to a quarantine queue
with the typed reason and safe replay command.

Pancake active reads make one transport attempt with a five-second connect
limit and separate ten-second limits for receiving response headers and the
bounded response body. Commerce does not retry inside the adapter.
`pancake-order-unavailable` carries
`retryable? #t` for transport failure, HTTP 408/429, or provider 5xx; the
durable worker owns exponential backoff and retry limits for the whole journaled
event. Merchant authentication, query rejection, not-found, malformed response,
and semantic mismatch require configuration repair or operator review rather
than an immediate tight loop.

## Backup and restore

Production requires encrypted, versioned backups of journal, projections,
outbox, entitlement lineage, issuance records, and provider mappings. Restore is
tested into an isolated environment and followed by deterministic projection
comparison before traffic is allowed.

## Manual actions

Manual reissue, refund response, subject recovery, and mapping repair require a
reason and append an audit record. The operator CLI shows the intended effect
and affected identifiers before mutation. Direct SQL is emergency diagnosis,
not a supported workflow.

