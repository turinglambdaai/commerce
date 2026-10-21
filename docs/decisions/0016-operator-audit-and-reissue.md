# ADR-0016: Operator audit, claim reissue, and the claim portal

- Status: Accepted
- Date: 2026-10-22

## Context

Operations promised three things the code did not yet deliver: manual
actions leave auditable evidence, a customer whose claim window passed
can still be helped, and claim fulfillment has a customer-facing surface.

## Decision

SQLite schema v7 adds two things:

- `commerce_operator_audit`, an append-only table naming the action, the
  accountable operator, a free reason of bounded length, one subject
  identifier, and the timestamp. Triggers reject updates and deletes.
  Every manual action in Commerce goes through it.
- The claim table drops its single-claim-per-credential uniqueness: the
  v7 migration rebuilds the table preserving all rows, so a reissue
  appends a fresh `ready` claim for the SAME issued credential instead of
  resetting evidence.

`storage-reissue-claim!` is the only reissue path: it requires the claim
id, a fresh random token, a new window, an operator name, and a reason;
it never creates a second credential or lineage revision; and it appends
the audit record in the same transaction.

`handle-claim-post` in `commerce/server` is the claim portal: the
customer's one-time token in, the exact signed Permit envelope JSON out.
Token possession is the only authorization; unknown tokens are 404,
reused tokens 409, expired tokens 410; fulfillment never advances a
lineage revision. The served route is `/claims`.

## Consequences

- Operators can finally answer "who did what, when, and why" from the
  database itself.
- Reissue cannot become a re-grant: the credential id and lineage are
  untouched, and the old claim row remains as evidence.
- The portal trusts the token over the transport; production deployments
  owe TLS and rate limiting as before.
