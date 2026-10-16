# ADR-0004: Pancake webhook authentication boundary

- Status: Accepted
- Date: 2026-10-16

## Context

Pancake webhook delivery is the first external trust boundary in Commerce.
Parsing JSON before authenticating its exact representation, accepting a stale
capture, or trying both test and production keys would let an ambiguous or
misrouted request cross that boundary.

The protocol baseline is the official
[Waffo Pancake Go SDK v0.17.0](https://github.com/waffo-com/waffo-pancake-sdk-go/tree/v0.17.0)
and its
[webhook guide](https://github.com/waffo-com/waffo-pancake-sdk-go/blob/v0.17.0/docs/webhook-guide.md),
released on 2026-10-10. Commerce's committed fixtures reproduce that public
wire contract with disposable local RSA keys. They are protocol-conformance
evidence, not a claim of live sandbox delivery.

## Decision

`commerce/pancake` exposes a local verifier, not an HTTP listener or a complete
provider adapter.

For `X-Waffo-Signature: t=<timestamp-ms>,v1=<base64-signature>`, the signed
bytes are exactly:

```text
ASCII decimal timestamp + "." + unmodified request-body bytes
```

The verifier uses RSA-SHA256 with PKCS#1 v1.5 padding. It copies the caller's
body bytes, parses the signature header without allowing missing or duplicate
`t`/`v1` fields, enforces the timestamp window, verifies the signature, and
only then parses JSON. Duplicate top-level JSON fields are rejected rather
than reduced to the last value.

The default replay window is 45 minutes into the past because Pancake stamps a
timestamp once and reuses it across retries whose observed schedule exceeds 31
minutes. Future clock skew is limited to one minute. The stable provider event
id remains the durable idempotency key; the time window is not a replacement
for journal replay protection.

Callers must select either `'test` or `'production`. Commerce intentionally
does not use the official SDK's prod-then-test auto-detection: a valid signature
under the wrong trust domain must fail closed. Test and production keys are
separate, and the verified payload's `mode` must agree with the selected
environment. The built-in public keys mirror v0.17.0; an explicit keyring
override supports controlled provider key rotation.

Failures use typed `exn:fail:commerce` codes. Error messages and data may
contain the selected environment, tolerance values, a SHA-256 payload digest,
or a field name. They must never contain raw request bytes, the signature
header, decoded signature material, public-key contents, order/customer data,
or parser/crypto exception text.

## Consequences

- A verified `pancake-webhook` is authenticated provider-native evidence, not
  yet a canonical `payment-event`.
- Active order lookup and semantic amount/offer/subject validation remain the
  next adapter boundary.
- HTTP acknowledgement, durable journal acceptance, projection, outbox,
  Permit signing, and claim delivery remain separate slices.
- Provider key changes require a reviewed keyring update and fixture/CI proof;
  no environment-variable fallback silently changes trust roots.
