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

## Stuck work

The operator surface distinguishes:

- event accepted but projection blocked;
- projection complete but issuance pending;
- credential signed but delivery unclaimed;
- retry scheduled versus terminal operator action required.

Every retry is bounded and observable. Poison work moves to a quarantine queue
with the typed reason and safe replay command.

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

