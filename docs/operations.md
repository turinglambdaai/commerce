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

The SQLite service store uses application id `COMM` and schema version 4.
Opening a schema-v1 journal creates the projection, outbox, lineage, and
delivery schema; opening schema v2 adds lineage and delivery tables; opening
schema v3 adds only the delivery tables. All migrations are atomic and
preserve existing evidence. Operational inspection should select identifiers
and status metadata, not `raw_payload`:

```sql
SELECT sequence, provider, event_id, event_kind, order_id, received_at
FROM commerce_event_journal
ORDER BY sequence;
```

Rows reject ordinary `UPDATE` and `DELETE`. Repair or future retention requires
a versioned, audited database operation; disabling the triggers for routine
customer support is not a supported workflow.

Projection progress and pending issuance work are inspected separately:

```sql
SELECT journal_sequence, status, failure_code, processed_at
FROM commerce_projection_event
ORDER BY journal_sequence;

SELECT id, idempotency_key, status, attempts, available_at,
       lease_owner, lease_expires_at, last_error_code
FROM commerce_issuance_outbox
ORDER BY id;

SELECT entitlement_id, issuer, subject_type, subject_id, offer_id, created_at
FROM commerce_entitlement_lineage
ORDER BY entitlement_id;

SELECT entitlement_id, revision, previous_revision, credential_id,
       issuance_outbox_id, action, policy_id, policy_version, issued_at
FROM commerce_entitlement_revision
ORDER BY entitlement_id, revision;
```

A missing projection-event row is safe pending work. `blocked` is terminal for
automatic projection and requires operator review. A projector crash within a
transaction leaves no order, outbox, or marker changes and the same journal
sequence is selected again.

## Stuck work

The operator surface distinguishes:

- event accepted but projection blocked;
- projection complete but issuance pending;
- credential signed but delivery unclaimed;
- retry scheduled versus terminal operator action required.

Every retry is bounded and observable. The projector records deterministic
poison work as a durable `blocked` marker with a typed reason; the broader
quarantine workflow remains future work. `commerce/operator` exposes the
headless replay vocabulary: `find-issuance-work` enumerates outbox rows,
`explain-order` answers "what happened to this order" with redacted
canonical events (raw provider bytes stay behind `commerce/journal`), and
`redrive-issuance-work!` makes one pending row due without touching its
attempts counter — it refuses to rewind in-flight or completed work. The
CLI wrapper is future work; this module is its entire implementation.

Claim delivery state is explicit: `ready` until the token is fulfilled,
`claimed` once fulfilled, and expired once the fulfillment window passes.
The claim token is shown to the customer exactly once and stored only as a
SHA-256 digest; operators inspect claim state by identifiers, never by
token. Notification timestamps are idempotent first-writer-wins marks.
Expired claims remain as audit rows; retention is a future versioned
operation.

Issuance rows are claimed through the storage lease contract: claim in a
short transaction, set `processing`, increment `attempts`, and store an
opaque owner and expiry; active leases are exclusive and expired leases are
reclaimable. Signing occurs outside that claim transaction, followed by
owner-checked completion. Release returns transient work to `pending` with a
typed error code and a future retry time; completion that already landed
reconciles to the recorded revision. No worker may infer authorization
merely from outbox status.

The `commerce/issuer` worker runs this loop: it claims one due row, refuses
deterministic dead ends before signing (released with the typed commerce
code and an operator backoff), signs the exact recorded bytes, and
completes. Permit signing failures release as `permit-issue-failed` with a
short backoff; after key or trust-store repair the same row completes.
Losing the lease between claim and completion reports `lease-lost` to the
caller and writes nothing.

Lineage roots and revision rows are written only by
`storage-complete-issuance-work!`, which appends the root plus revision zero
or exactly one successor in the same transaction that completes the outbox
row. Revision rows retain exact unsigned Permit payload bytes and their
digest; issued-credential rows retain the exact signed envelope bytes.
Routine inspection omits those bytes.

Pancake active reads make one transport attempt with a five-second connect
limit and separate ten-second limits for receiving response headers and the
bounded response body. Commerce does not retry inside the adapter.
`pancake-order-unavailable` carries
`retryable? #t` for transport failure, HTTP 408/429, or provider 5xx; the
durable worker owns exponential backoff and retry limits for the whole journaled
event. Merchant authentication, query rejection, not-found, malformed response,
and semantic mismatch require configuration repair or operator review rather
than an immediate tight loop.

## Webhook endpoint

`commerce/server` exposes one route that authenticates the exact request
bytes, resolves the durable checkout binding, actively verifies the
order, and journals. Status codes: 200 for accepted or exactly-replayed
webhooks, 401 for anything that fails authentication (no evidence is
created), 404 for orders with no durable checkout expectation, 409 for
conflicting replays, 422 for semantic mismatches (operator review), and
503 when the provider read is retryably unavailable so the provider
retries. No issuance or delivery ever runs in the request path.
Production deployments terminate TLS, enforce request limits, and ship
the commerce log topic; the edge itself deliberately does none of that.

## Readiness and stuck work

`storage-readiness` returns one read-only snapshot: schema version, journal
and projection counts, pending/processing issuance work with a stale-lease
count, the oldest pending availability time, and claim states including the
window-passed count. `commerce/health` classifies that snapshot into typed
warnings — `projection-blocked`, `issuance-lease-expired`,
`claim-window-passed` — and `health-report!` logs them on the commerce
topic so a scheduled check leaves the same evidence a human would read.
The future HTTP edge renders this value; the classification itself is
transport-neutral and mutates nothing.

## Operator CLI

`raco commerce` wraps the operator surface for one service database:

```bash
raco commerce find    <database> [pending|processing|completed]
raco commerce explain <database> <provider> <order-id>
raco commerce redrive <database> <idempotency-key>
```

Output is JSON with redacted summaries only (canonical events, workflow
state, credential metadata with an envelope digest). `redrive` exits 0 on
success and 1 with a typed `code` on refusal. Direct SQL is emergency
diagnosis; this CLI is the supported workflow.

## Observability

`commerce/log` is the single logging path. Events are structured and
redacted by construction — whitelisted correlation keys (provider, event
id, order id, subject, offer, outbox work, entitlement and revision, claim)
and whitelisted scalar fields only; raw provider bytes, tokens, and keys
are rejected before emission. Exact replays and idle polling log at debug;
transitions log at info; conflicts, refusals, and lost leases log at
warning. Ship the `commerce` topic as JSON lines in deployment; the
library never formats or ships logs itself.

## Backup and restore

Production requires encrypted, versioned backups of journal, projections,
outbox, entitlement lineage, issued credentials, and provider mappings.
`snapshot-commerce-database!` writes the consistent copy; encryption and
shipping belong to deployment tooling. Restore is rehearsed with
`verify-commerce-backup` — integrity, database identity, schema version,
and journal counts — into an isolated environment before traffic is
allowed.

## Retention

Claims whose fulfillment window passed retire to the terminal `expired`
state through `storage-retire-expired-claims!` (also exposed as
`commerce/retention`); they remain as audit rows and fulfillment refuses
them either way. Deletion of journal, lineage, issued-credential, or claim
rows is never a routine operation: it requires a versioned, audited schema
operation with its own ADR, reviewed redaction, and a backup taken first.

## Manual actions

Every manual action appends an immutable `commerce_operator_audit` row —
action, operator, reason, subject, timestamp — through
`storage-append-audit!`. Direct SQL is emergency diagnosis, not a
supported workflow.

Claim reissue (`storage-reissue-claim!`) helps a customer whose claim
window passed: it appends a fresh `ready` claim for the SAME issued
credential — never a second credential or lineage revision — and writes
the audit record in the same transaction. The old claim row remains.

## Claim portal and reconciliation

The served endpoint exposes `/claims`: the customer's one-time token
in, the signed Permit envelope out. Unknown tokens are 404, reused 409,
expired 410; fulfillment never advances a lineage revision.

`commerce/reconcile` compares bounded provider order facts with local
projections and reports typed differences (`missing-webhook`,
`provider-disagrees`, `provider-order-not-found`,
`provider-read-refused`). It is read-only: differences are operator
signals, and missing facts still enter through the webhook/journal
path — commercial truth keeps exactly one ingress.

