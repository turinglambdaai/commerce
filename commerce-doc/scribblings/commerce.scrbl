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
timestamp through the @tt{pancake-webhook-*} accessors. It is not a canonical
@tt{payment-event}; active order verification remains required.

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

@section{Durable event journal}

Server processes explicitly require @filepath{commerce/journal.rkt}. The
filesystem backend is selected separately with
@filepath{commerce/journal/sqlite.rkt}; neither module is re-exported from the
default product-safe facade.

@verbatim{
(open-sqlite-event-journal database-path) -> event-journal?
  database-path : path-string?
}

Opens or creates a Commerce-owned SQLite database. Schema v1 uses WAL mode,
full commit synchronization, and database triggers that reject updates or
deletes of accepted event rows.

@verbatim{
(journal-accept! journal raw-payload event #:received-at received-at)
  -> journal-acceptance?
  journal     : event-journal?
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
(journal-ref journal provider event-id)
  -> (or/c journal-record? #f)

(journal-close journal) -> void?
}

@tt{journal-ref} returns the original sequence, canonical event, immutable raw
payload, and receive time. Call @tt{journal-close} during service shutdown.

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
