# Concepts

Commerce keeps its vocabulary smaller than any payment provider's API. The
point is not to hide every difference; it is to make the durable product-family
decisions explicit.

## Product

A stable software identity such as `taskly` or `autarx`. Product ids are
kebab-case and never contain a provider name, billing period, or price.

## Offer

The smallest thing a customer can intentionally buy. An Offer binds:

- a stable offer id;
- one Product;
- a commercial kind (`one-time` or `subscription`);
- an exact display price for a configured sales path;
- an entitlement policy id.

`taskly-pro-lifetime` is an Offer. A Pancake product id and a ZPAY product name
are provider mappings for that Offer; they are not the Offer's identity.

## Payment event

An immutable provider fact emitted only after native authentication and
semantic checks. The initial canonical vocabulary is deliberately small:

- `payment-succeeded`
- `payment-refunded`

Provider details remain in the immutable raw journal and adapter-owned metadata.
They are not copied into the shared core without a cross-provider invariant.

## Order projection

The minimal current view derived from payment events for one provider order.
The projection records commercial identity, exact amount, paid evidence, and
refund evidence. It is rebuildable from the journal.

The core tolerates out-of-order delivery. If refund evidence arrives before
payment evidence, the later payment never produces a grant.

## Rights intent

An auditable request produced by a commercial transition. `grant` means the
current offer policy should produce or advance a Permit entitlement. `withdraw`
means the policy must respond to refund/chargeback evidence.

A rights intent is not itself authorization, and `withdraw` is not a claim that
an offline credential has been remotely revoked. The Permit integration chooses
the honest mechanism available to that product.

## Issuance

The server-side operation that resolves an Offer's policy, loads the entitlement
lineage, creates a complete next revision, signs it through `permit/issuer`, and
records delivery. Issuance is asynchronous and idempotent.

## Claim

A short-lived, single-purpose delivery mechanism through which an application
or customer retrieves an issued credential. Claim tokens are not credentials,
accounts, or authorization evidence.

