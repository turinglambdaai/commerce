# ADR-0012: Operator replay surface

- Status: Accepted
- Date: 2026-10-21

## Context

Refunds and stuck work are operator surfaces, not exception paths. The
journal, projection, lease, and claim layers already behave correctly under
replay; what was missing was the explicit read-and-redrive vocabulary an
operator needs when a customer says "I paid" or "I refunded", without raw
payload access becoming the default tool.

## Decision

`commerce/operator` is an explicit server-side module — the future CLI
reuses it — with three operations:

- `find-issuance-work` enumerates outbox rows in stable id order, optionally
  filtered by status. Read-only.
- `explain-order` answers "what happened to this provider order" with the
  order projection, the canonical event snapshots (never raw provider
  bytes), the order's outbox work, and its issued-credential records, if
  any. Deep journal payload access stays behind `commerce/journal` for
  explicit diagnosis.
- `redrive-issuance-work!` makes one `pending` row due immediately without
  touching its attempts counter. It is the bounded answer to transient
  failures and short backoffs; it refuses to rewind in-flight work
  (`lease-not-held`) or completed work (`work-already-completed`), and
  unknown keys fail with `unknown-issuance-work`.

Replay discipline is unchanged and now explicit: an exact journal replay is
acknowledged without a second projection or outbox row, projection reuses
the immutable journal through the normal path, and no operator operation
edits a projection row. Blocked projection markers remain terminal for
automatic processing; their quarantine workflow is future work.

## Refund semantics

A refund after payment emits one withdrawal intent whose issuance records a
complete successor revision expiring at its own issuance. That is the whole
honest effect: an older offline credential remains usable until another
product mechanism reaches it. Operators must describe this actual mechanism,
not a revocation that does not happen.

## Consequences

- The operator vocabulary is testable headlessly; the M2 CLI becomes a thin
  wrapper instead of a second implementation.
- Redrive cannot mask poison work: deterministic refusals stay typed,
  visible, and bounded.
- Audit records for manual actions (reason + actor) remain future work for
  the M2 operational baseline.
