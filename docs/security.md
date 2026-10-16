# Security

Commerce crosses money, identity, and product-rights trust boundaries. Secure
defaults are part of the domain model, not deployment polish.

## Threats in scope

- forged, modified, replayed, duplicated, delayed, or reordered webhooks;
- event-id reuse with different content;
- amount, currency, offer, or subject substitution;
- test/live environment confusion;
- leaked provider secrets or Permit signing keys;
- double issuance after retry or worker crash;
- logs/backups exposing personal or payment-adjacent data;
- an operator replaying the wrong event or issuing the wrong entitlement;
- a compromised product client attempting to mint rights.

## Rules

1. Authenticate exact raw input before canonical parsing.
2. Persist the authenticated raw event and its digest before acknowledgement.
3. Use exact minor-unit integers and compare expected amount/currency.
4. Bind provider product/price identifiers to a configured Offer server-side.
5. Treat redirects and client claims as untrusted hints.
6. Make projection and outbox insertion atomic.
7. Make every consumer idempotent and crash-replayable.
8. Keep products unable to construct verified payment facts or sign credentials.
9. Redact secrets and personal data structurally before logging.
10. Separate live/test databases, secrets, keys, provider ids, and hostnames.

## Key custody

No production private key or provider secret is committed, bundled, printed, or
stored in ordinary configuration. Environment variables are acceptable only as
a deployment injection mechanism, not as a long-term secret-management design.

Permit signing should eventually run through a narrow signer interface so the
Commerce web edge cannot read/export the raw key. Key identifiers and rotation
state are recorded with every issuance.

## Customer identity

Commerce stores an opaque stable subject id established by a verified product
or identity flow. Email, name, and provider customer ids are mappings or
display/contact data. A change of email must not create a new entitlement owner
or grant access to an existing one without a verified recovery flow owned by
the product or identity service.

## Offline limits

Commerce cannot revoke a credential held by a permanently offline, locally
controlled client. Products requiring timely refund enforcement, subscription
expiry, or device reclamation use activation leases or another explicit online
mechanism. Documentation and UI must not promise stronger control than the
system provides.

## Security evidence before production

- captured valid/invalid provider fixtures;
- replay, reordering, amount-conflict, signature-failure, and timeout tests;
- redaction tests against emitted logs and failure artifacts;
- transactional crash tests at every journal/projection/outbox boundary;
- restore rehearsal from encrypted backups;
- staging and production key-rotation drills;
- operator runbooks exercised without direct database editing.

