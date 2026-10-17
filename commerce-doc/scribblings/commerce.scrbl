#lang scribble/manual

@title{Commerce}
@author{TuringLambdaAI}

Public module: @tt{commerce}

Commerce is a provider-neutral commercial management core: authenticated
payment facts enter, deterministic order projections and rights intents leave.
It orchestrates payment providers and a Permit issuer without moving payment or
authorization policy into Rivet, Glaze, Keel, or product clients.

The default module is pure. Provider adapters explicitly require
@filepath{commerce/provider.rkt} to construct verified canonical events after
their native authentication and semantic checks.

@section{Values}

@subsection{Money}

@verbatim{
(money currency minor-units) -> money?
  currency    : string?
  minor-units : exact-nonnegative-integer?
}

Represents money exactly in the currency's smallest configured unit. Currency
is an uppercase three-letter ISO 4217 code. Floating-point amounts are rejected.

@subsection{Offer}

@verbatim{
(offer id product-id kind price entitlement-policy-id) -> offer?
  id                    : string?
  product-id            : string?
  kind                  : (or/c 'one-time 'subscription)
  price                 : money?
  entitlement-policy-id : string?
}

Describes one stable thing a customer may buy. Identifiers are lowercase
kebab-case. Provider product and price identifiers are mappings owned by the
service and are not part of this value.

@section{Projection API}

@verbatim{
(empty-commerce-state) -> commerce-state?
}

Returns an empty immutable projection state.

@verbatim{
(ingest-payment-event state event)
  -> commerce-state? (listof rights-intent?)
  state : commerce-state?
  event : payment-event?
}

Applies one previously verified provider event. Exact replay returns the same
state and an empty intent list. Conflicting replay or changed order identity
raises an @tt{exn:fail:commerce} value.

@verbatim{
(commerce-state-order state provider order-id)
  -> (or/c order-projection? #f)
}

Returns the current projection for one provider order.

@verbatim{
(commerce-state-intents state) -> (listof rights-intent?)
}

Returns all emitted rights intents sorted by their idempotency keys.

@section{Provider boundary}

Provider adapters require @filepath{commerce/provider.rkt} and construct a
canonical event only after authenticating the exact raw input, mapping the
Offer and subject, checking amount and currency, and performing any active
order lookup required by the provider contract.

@verbatim{
(make-verified-payment-event
 provider event-id payload-digest kind order-id offer-id
 subject-id amount occurred-at)
 -> payment-event?
}

Product clients must not call this function.

@section{Pancake webhook authentication}

Server processes explicitly require @filepath{commerce/pancake.rkt}. This
module authenticates provider-native evidence and is not re-exported by the
default facade.

@verbatim{
(verify-pancake-webhook
 raw-body signature-header
 #:environment environment
 [#:keyring keyring]
 [#:now-ms now-ms]
 [#:past-tolerance-ms past-tolerance-ms]
 [#:future-tolerance-ms future-tolerance-ms])
 -> pancake-webhook?
  raw-body        : bytes?
  signature-header : string?
  environment     : (or/c 'test 'production)
}

Verifies the @tt{X-Waffo-Signature} RSA-SHA256 signature over the decimal
millisecond timestamp, one period byte, and the exact copied request bytes.
The default window accepts up to 45 minutes of retry age and one minute of
future clock skew. JSON parsing happens only after verification. The signed
payload's mode must match the explicitly selected environment, and duplicate
top-level fields are rejected.

The returned value exposes environment, envelope identifiers, event and store
metadata, data, immutable raw bytes, their SHA-256 digest, and the signature
timestamp through the @tt{pancake-webhook-*} accessors. It is provider-native
evidence and is not yet a canonical @tt{payment-event}.

@verbatim{
(pancake-webhook-keyring test-public-key production-public-key)
 -> pancake-webhook-keyring?
}

An explicit keyring supports controlled provider key rotation. Test and
production keys must be non-empty and distinct. Authentication and payload
failures raise redacted @tt{exn:fail:commerce} values; raw bodies, signatures,
and key contents are never included. Codes distinguish missing or malformed
signature headers, invalid or out-of-window timestamps, invalid signatures,
invalid configured public keys, invalid payloads, and environment mismatch.

@subsection{Pancake active one-time order verification}

@verbatim{
(pancake-order-binding
 merchant-external-id product-id offer-id subject-id amount currency-exponent)
 -> pancake-order-binding?
}

Records the server-side expectation created with checkout. The merchant
external id is a random correlation reference of at most 128 characters. It
maps locally to one provider product, stable Offer, opaque stable subject,
expected @tt{money} value, and explicit ISO 4217 exponent from zero through
four. It must not contain or substitute for the subject identity.

@verbatim{
(make-pancake-merchant-client
 merchant-id private-key-pem
 #:environment environment
 [#:connect-timeout-seconds connect-timeout]
 [#:request-timeout-seconds request-timeout]
 [#:transport transport]
 [#:clock clock])
 -> pancake-merchant-client?
}

Creates an opaque server-side client. The RSA private key is parsed once and is
not exposed by accessors. The client signs one @tt{POST /v1/graphql} merchant
read with RSA-SHA256/PKCS#1 v1.5. Both environments use
@tt{https://api.waffo.ai/v1/graphql}; the explicit environment is verified
against the returned order's @tt{testMode}. Defaults are five seconds to
connect and ten seconds for response headers and body. Reads follow no
redirects, carry no idempotency key, and make no implicit retry.

@verbatim{
(verify-pancake-onetime-order client webhook binding) -> payment-event?
}

Requires an authenticated @tt{order.completed} webhook, actively reads its
one-time order, and checks order id, completed status, environment, store,
merchant external id, product, the webhook payment id and succeeded status,
currency, and exact payment total. Decimal display money is converted directly
to configured minor units without floating point. Only a complete match
constructs the canonical event.

Transport failure and HTTP 408/429/5xx raise retryable
@tt{pancake-order-unavailable}. Merchant authentication, GraphQL rejection,
missing or malformed orders, and each semantic mismatch have separate typed,
redacted codes. The optional transport and clock arguments on
@tt{make-pancake-merchant-client} exist for deterministic integration testing;
production callers normally leave them at their secure defaults.

@section{Durable event journal}

Server processes explicitly require @filepath{commerce/journal.rkt},
@filepath{commerce/storage.rkt}, and
@filepath{commerce/storage/sqlite.rkt}. None is re-exported from the default
product-safe facade.

@verbatim{
(open-sqlite-commerce-storage database-path) -> commerce-storage?
  database-path : path-string?
}

Opens or creates a Commerce-owned SQLite database. Schema v3 uses WAL mode,
full commit synchronization, foreign keys, and database triggers that reject
updates or deletes of accepted event and entitlement-lineage evidence. Schema
v1 and v2 databases migrate in place without rewriting existing rows. The v3
lineage tables retain stable entitlement roots and contiguous revisions with
exact unsigned Permit payload bytes; no public lineage writer, lease mutation,
signer, or signed-credential storage is exposed yet.

@verbatim{
(journal-accept! storage raw-payload event #:received-at received-at)
  -> journal-acceptance?
  storage     : commerce-storage?
  raw-payload : bytes?
  event       : payment-event?
  received-at : exact-nonnegative-integer?
}

Copies and hashes the exact authenticated bytes, then durably stores them with
the canonical payment-event snapshot. The acceptance disposition is
@tt{'accepted} for a newly committed row or @tt{'replayed} for an exact retry.
The same provider event id with changed raw or canonical content raises an
@tt{exn:fail:commerce} whose code is @tt{'event-conflict}. Digest mismatch is
rejected before persistence.

@verbatim{
(journal-ref storage provider event-id)
  -> (or/c journal-record? #f)
}

@tt{journal-ref} returns the original sequence, canonical event, immutable raw
payload, and receive time.

@section{Durable projection and issuance outbox}

Journal acknowledgement and projection are separate durability phases.
Projection runs outside the provider request:

@verbatim{
(storage-project-next! storage #:processed-at processed-at)
  -> (or/c projection-result? #f)
  processed-at : exact-nonnegative-integer?
}

Selects the lowest unprocessed journal sequence and atomically writes its order
projection, any newly emitted issuance-outbox row, and its processing marker.
It returns @tt{#f} when no sequence is pending. A successful result has
disposition @tt{'projected}; an order identity conflict has disposition
@tt{'blocked}, failure code @tt{'order-conflict}, no new outbox items, and
leaves the previous order unchanged.

@verbatim{
(storage-order-ref storage provider order-id)
  -> (or/c order-projection? #f)

(storage-outbox-ref storage idempotency-key)
  -> (or/c issuance-outbox-item? #f)

(storage-close storage) -> void?
}

@tt{projection-result} exposes disposition, journal sequence, resulting order,
new outbox items, and optional failure code. Each
@tt{issuance-outbox-item} exposes its stable idempotency key, source sequence,
rights action and commercial identifiers, occurrence time, and workflow state.
New rows are @tt{'pending} with zero attempts and no lease. This release does
not expose lease mutation or Permit signing APIs. Call @tt{storage-close}
during service shutdown.

@section{Offer-to-Permit policy mapping}

Server processes explicitly require @filepath{commerce/permit.rkt}. This
module imports the published @tt{permit/issuer} snapshot surface; it is not
re-exported from the default facade and never accesses a signing key.

@verbatim{
(make-permit-grant-policy
 [#:products products]
 [#:product-families product-families]
 [#:edition edition]
 [#:feature-policy feature-policy]
 [#:features features]
 [#:addons addons]
 [#:capabilities capabilities])
 -> permit-grant-policy?
}

Constructs one reviewed grant policy. Optional Commerce values use @tt{#f};
the adapter translates absence to Permit @tt{null}. The smart constructor
validates the resulting grant through Permit's complete entitlement schema.
Feature policy is @tt{'explicit} or @tt{'published-through}.

@verbatim{
(make-permit-constraints-policy
 [#:use-expires-at use-expires-at]
 [#:updates-through updates-through]
 [#:features-through features-through]
 [#:version-min version-min]
 [#:version-max version-max]
 [#:named-seats named-seats]
 [#:device-activations device-activations]
 [#:concurrent-seats concurrent-seats]
 [#:installation-id installation-id]
 [#:activation-required? activation-required?])
 -> permit-constraints-policy?
}

Constructs the complete constraints policy and validates timestamps, SemVer
bounds, limits, installation binding, and activation shape through Permit.

@verbatim{
(make-permit-entitlement-policy
 id version
 #:subject-type subject-type
 #:grants grants
 [#:constraints constraints]
 [#:withdrawal-mode 'expire-at-issuance])
 -> permit-entitlement-policy?

(make-permit-policy-catalog
 offers policies
 [#:deleted-offer-ids deleted-offer-ids])
 -> permit-policy-catalog?
}

Policy ids are immutable revisions; the positive integer version is audit
metadata and never selects a mutable latest policy. The catalog contains both
active and retained retired Offer definitions. Explicit deletion tombstones
are distinct from never-known Offer ids. Every Offer's product must occur in
the explicit product scope of its pinned policy.

@verbatim{
(prepare-permit-snapshot
 catalog intent
 #:issuer issuer
 #:credential-id credential-id
 #:entitlement-id entitlement-id
 #:issued-at issued-at
 [#:previous previous])
 -> permit-snapshot-request?
}

For @tt{'grant}, creates a complete entitlement at revision 0 and rejects an
existing lineage. For @tt{'withdraw}, requires the previous complete snapshot,
checks issuer, entitlement id, subject, type, and grants, advances its revision,
and sets @tt{use_expires_at} to the new @tt{issued_at}. This communicates an
issuance-expiring successor to connected clients; it does not revoke an old
offline credential.

The result exposes policy id/version, action, source idempotency key, the
validated complete payload, and @tt{permit-snapshot-request-payload-bytes}.
The payload tree and bytes are immutable copies. Those bytes are Permit's
single serialization and are the only bytes a later signer may sign.
Unknown/deleted Offers, invalid policy/catalog/request data,
unsupported kinds/actions, and missing or conflicting lineage raise typed
@tt{exn:fail:commerce} values. No outbox mutation, lineage persistence,
signing, or delivery happens in this operation.

@section{First purchase}

@verbatim{
#lang racket/base

(require commerce
         commerce/provider)

(define paid
  (make-verified-payment-event
   "mock" "evt_1" (make-string 64 #\a)
   'payment-succeeded
   "ord_1" "taskly-pro-lifetime" "customer-1"
   (money "USD" 2900)
   1792108800))

(define-values (state intents)
  (ingest-payment-event (empty-commerce-state) paid))
}

The complete architecture, provider rules, security model, operations contract,
and Permit integration are maintained in the repository's @filepath{docs/}
directory.
