# Operator runbook

This runbook answers the questions an operator actually gets, in the words
a customer uses. Every answer names the real mechanism, never a desired
outcome. The runnable end-to-end journey behind these answers is
`examples/full-journey.rkt`; run it any time to see each stage print its
evidence.

```bash
racket examples/full-journey.rkt
```

## "I paid, but Pro is not active."

Work through the chain in order and stop at the first broken link:

1. **Did the webhook arrive and authenticate?** Journal evidence:

   ```sql
   SELECT sequence, provider, event_id, event_kind, order_id, received_at
   FROM commerce_event_journal WHERE provider = ? AND order_id = ?
   ORDER BY sequence;
   ```

   No row means the webhook never arrived or failed authentication — the
   provider must redeliver; Commerce has nothing to replay.

2. **Is the journal row projected?** A missing
   `commerce_projection_event` row is pending work — run the projector. A
   `blocked` row with `order-conflict` is terminal for automatic
   processing: the order's offer, subject, or amount changed across
   events. That is quarantine territory; keep the evidence and escalate.

3. **Is issuance work still pending?**

   ```sql
   SELECT id, idempotency_key, status, attempts, available_at,
          lease_owner, lease_expires_at, last_error_code
   FROM commerce_issuance_outbox ORDER BY id;
   ```

   - `pending` with a future `available_at`: transient backoff is running.
     To retry now, use `redrive-issuance-work!` (see below).
   - `pending` with `last_error_code` set: read the code. Deterministic
     codes (`unknown-offer`, `offer-deleted`, `unsupported-offer-kind`,
     `entitlement-lineage-conflict`, `entitlement-lineage-required`) are
     configuration or data repair, not retries — redriving them repeats the
     same typed refusal.
   - `processing` with an expired lease: the worker died mid-flight; the
     row is reclaimable and `attempts` shows how many starts it had.
   - `completed`: the credential was signed and recorded.

4. **Was a credential issued and claimed?** `explain-order` returns the
   order projection, canonical events, outbox work, and issued-credential
   records in one call:

   ```racket
   (require commerce/operator)
   (explain-order storage "pancake" "ORD_xxx")
   ```

   If the claim is still `ready`, the customer never received (or never
   used) their claim token. If it is `claimed`, the credential bytes were
   fulfilled once; check the product side for the stored credential.

## Replay and redrive

Replay always reuses the immutable journal through the normal projection
path. An exact redelivery of a webhook is acknowledged without a second
projection or outbox row; a changed payload under the same event id is
rejected as `event-conflict` and must be investigated, never overwritten.
No operator operation edits a projection row.

`redrive-issuance-work!` makes one pending issuance row due immediately
without touching its attempts counter. It refuses in-flight work
(`lease-not-held`) and completed work (`work-already-completed`); unknown
keys fail with `unknown-issuance-work`. Bounded backoff plus observable
attempts is the normal recovery path; redrive is for "the backoff is
longer than the customer's patience" moments.

## Recovery routes

Every failure a customer hits has exactly one route back, and every
route reuses the logical order — none of them asks the customer to pay
again, and none of them treats a redirect or a repeat purchase attempt
as payment evidence. `commerce-test/recovery-test.rkt` walks all four
routes end to end at the fixture boundary; live checkout remains a
separate launch gate (see the sandbox drill below).

- **The webhook arrived late.** The journal is idempotent: a late
  delivery follows the ordinary accept → project → issue path and
  converges on one credential. Reconciliation may surface the gap first
  as a `missing-webhook` difference; the late webhook closes it on
  arrival, and the provider's redelivery is acknowledged as `replayed`.
- **The callback was delivered twice.** An exact redelivery is
  acknowledged as `replayed` without a second journal row, projection,
  or outbox entry. Changed bytes under the same event id are refused as
  `conflicting-replay` (HTTP 409) and must be investigated, never
  overwritten.
- **The browser return was lost.** If no webhook ever arrives,
  reconciliation compares a signed provider order read with the empty
  projection and reports `missing-webhook`. Reconciliation itself never
  mutates; the one route back is provider redelivery of the webhook,
  and the journal does the rest exactly once for the same logical
  order and entitlement.
- **The credential import failed.** If the claim was fulfilled but the
  product could not import the bytes, the operator reissue path
  (`storage-reissue-claim!`) appends a fresh one-time claim for the
  SAME issued credential with a fresh token, recorded in the operator
  audit table. The credential id and lineage revision never change;
  the spent claim row stays as evidence.

## "I want a refund."

A refund after payment emits one withdrawal intent whose issuance records
a complete successor revision expiring at its own issuance. That is the
entire mechanism, and the runbook wording matters:

- **What actually happens:** credentials issued after the refund carry
  `use_expires_at` equal to their issuance time, so they grant nothing.
  Connected clients that refresh see the expired successor.
- **What does not happen:** an already-delivered offline credential is not
  remotely revoked. Revoking offline credentials requires a product-level
  mechanism (activation leases, signed revocation state, hosted-service
  suspension) chosen deliberately per product.

Never tell a customer a refund "deactivated" their offline copy.

## Claim tokens

The claim token is shown to the customer exactly once and stored only as a
SHA-256 digest. Operators cannot look up a claim by token — only by the
order, entitlement, or claim identifiers. States:

- `ready`: signed, notified (perhaps), awaiting fulfillment.
- `claimed`: fulfilled once; the envelope bytes left the building.
- expired: the fulfillment window passed. The row stays for audit;
  reissue is a deliberate, audited future operation, not a token reset.

## Backup, restore, and rotation drills

`snapshot-commerce-database!` writes one consistent copy through SQLite's
`VACUUM INTO` while the service runs; encrypt and ship the copy with your
deployment tooling (age/KMS), never inside Commerce. Rehearse restores,
not backups: `verify-commerce-backup` opens the copy, checks integrity and
the Commerce database identity, and compares journal counts against the
original — a rehearsal that only "the file exists" proves nothing.

Key rotation is two drills, both rehearsed before you need them:

- **Permit signing keys:** add the new public key to the trust store as
  `next`, switch `active`, move the old key to `retired`. New revisions
  record their own `key_id`, so one lineage can carry revisions signed by
  different keys; verifiers trust both while the old key is retired but
  still trusted.
- **Provider secrets:** rotate the Pancake merchant private key and update
  the webhook public-key keyring in one maintenance window; the journal
  keeps verifying old events (digests are already recorded), and only new
  reads and webhooks touch the new keys.

## Live sandbox drill

The repository's end-to-end evidence is deterministic (generated keys,
captured protocol shapes) so it runs anywhere. Before production, run the
same journey against Pancake's live test environment:

1. Obtain sandbox merchant credentials and the sandbox webhook public key.
2. Configure the merchant client with the sandbox private key; keep the
   keyring's test key pointed at the sandbox public key.
3. Create a checkout through Pancake's test store, pay it, and capture the
   webhook; let `verify-pancake-webhook`, `verify-pancake-onetime-order`,
   and the journey's remaining stages run unmodified.
4. Record the captured request/response pair as a protocol fixture with a
   redaction review, then extend the fixture corpus and this drill.

Production credentials never live in this repository or its CI.
