# Permit integration

Commerce consumes Permit's issuer-side API; Permit never depends on Commerce.

## Flow

```text
rights intent
    |
    v
resolve Offer entitlement policy
    |
    v
load entitlement lineage and highest issued revision
    |
    v
construct a complete next rights snapshot
    |
    v
permit/issuer signs exact payload bytes
    |
    v
record credential + issuance audit + delivery claim
```

An Offer references a stable policy id, not a serialized provider object and
not arbitrary Permit JSON supplied by the client. Policy configuration is
versioned and reviewed with code.

## Purchase

A first successful purchase normally creates revision 0 with a stable internal
subject id and complete grants/constraints. Reprocessing the same rights intent
returns the recorded issuance result.

## Renewal and plan change

Renewal, upgrade, downgrade, seat change, and bundle change issue a complete new
revision in the same entitlement lineage. Commerce does not patch an old signed
credential.

## Refund and chargeback

A `withdraw` intent records commercial evidence; it does not claim impossible
offline revocation. Each product policy chooses one honest response:

- accept the risk for a low-value perpetual offline purchase;
- require a short activation lease during the refund window;
- issue a newer restricted/expired revision to connected clients;
- distribute signed revocation state when supported;
- suspend future hosted service while leaving promised offline rights intact.

The operator UI and customer communication must describe the actual mechanism,
not the desired outcome.

## Trust domains

Permit credential-signing keys are distinct from:

- provider API/webhook secrets;
- Commerce claim-token secrets;
- update manifest/artifact keys;
- OS code-signing identities;
- database encryption and backup keys.

Production signing belongs behind an explicit issuer adapter and secret store.
The default Commerce facade never imports `permit/issuer`.

