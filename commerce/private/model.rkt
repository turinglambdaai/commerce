#lang racket/base

(provide
 (struct-out money)
 (struct-out offer)
 (struct-out payment-event)
 (struct-out order-projection)
 (struct-out rights-intent)
 (struct-out commerce-state)
 (struct-out checkout-session)
 (struct-out provider-adapter)
 (struct-out exn:fail:commerce)
 stable-id?
 opaque-id?
 sha256-hex?)

(require racket/match
         racket/string)

(define stable-id-rx #px"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
(define currency-rx #px"^[A-Z]{3}$")
(define sha256-rx #px"^[0-9a-f]{64}$")

(define (stable-id? value)
  (and (string? value)
       (<= 1 (string-length value) 96)
       (regexp-match? stable-id-rx value)))

(define (opaque-id? value)
  (and (string? value)
       (<= 1 (string-length value) 256)))

(define (sha256-hex? value)
  (and (string? value)
       (regexp-match? sha256-rx value)))

(define (guard who predicate description value)
  (unless (predicate value)
    (raise-argument-error who description value))
  value)

(struct exn:fail:commerce exn:fail (code data) #:transparent)

(struct money (currency minor-units)
  #:transparent
  #:guard
  (lambda (currency minor-units who)
    (values
     (guard who
            (lambda (value)
              (and (string? value) (regexp-match? currency-rx value)))
            "an uppercase ISO 4217 currency code"
            currency)
     (guard who exact-nonnegative-integer? "exact-nonnegative-integer?" minor-units))))

(struct offer (id product-id kind price entitlement-policy-id)
  #:transparent
  #:guard
  (lambda (id product-id kind price entitlement-policy-id who)
    (unless (memq kind '(one-time subscription))
      (raise-argument-error who "(or/c 'one-time 'subscription)" kind))
    (values
     (guard who stable-id? "stable kebab-case identifier" id)
     (guard who stable-id? "stable kebab-case identifier" product-id)
     kind
     (guard who money? "money?" price)
     (guard who stable-id? "stable kebab-case identifier" entitlement-policy-id))))

;; Only commerce/provider exports the constructor. The core receives payment
;; events that have already crossed a provider-native authentication boundary.
(struct payment-event
  (provider event-id payload-digest kind order-id offer-id subject-id amount
            occurred-at)
  #:transparent
  #:guard
  (lambda (provider event-id payload-digest kind order-id offer-id subject-id
                    amount occurred-at who)
    (unless (memq kind '(payment-succeeded payment-refunded))
      (raise-argument-error
       who
       "(or/c 'payment-succeeded 'payment-refunded)"
       kind))
    (values
     (guard who stable-id? "stable kebab-case provider identifier" provider)
     (guard who opaque-id? "non-empty opaque provider event identifier" event-id)
     (guard who sha256-hex? "lowercase SHA-256 hex digest" payload-digest)
     kind
     (guard who opaque-id? "non-empty opaque provider order identifier" order-id)
     (guard who stable-id? "stable kebab-case offer identifier" offer-id)
     (guard who opaque-id? "non-empty stable subject identifier" subject-id)
     (guard who money? "money?" amount)
     (guard who exact-nonnegative-integer? "UTC epoch seconds" occurred-at))))

(struct order-projection
  (provider order-id offer-id subject-id amount paid? refunded? paid-at
            refunded-at)
  #:transparent)

(struct rights-intent
  (idempotency-key action provider order-id offer-id subject-id occurred-at)
  #:transparent)

(struct commerce-state (events orders rights-intents-by-key) #:transparent)

(struct checkout-session (provider session-id url expires-at)
  #:transparent
  #:guard
  (lambda (provider session-id url expires-at who)
    (values
     (guard who stable-id? "stable kebab-case provider identifier" provider)
     (guard who opaque-id? "non-empty opaque checkout session identifier" session-id)
     (guard who
            (lambda (value)
              (and (string? value)
                   (or (string-prefix? value "https://")
                       (string-prefix? value "http://localhost"))))
            "HTTPS URL or localhost development URL"
            url)
     (guard who exact-nonnegative-integer? "UTC epoch seconds" expires-at))))

;; The procedures intentionally exchange provider-neutral values. Adapters keep
;; provider SDK objects, raw payloads, and secrets behind their own boundary.
(struct provider-adapter
  (id create-checkout verify-webhook fetch-order)
  #:transparent
  #:guard
  (lambda (id create-checkout verify-webhook fetch-order who)
    (values
     (guard who stable-id? "stable kebab-case provider identifier" id)
     (guard who procedure? "procedure?" create-checkout)
     (guard who procedure? "procedure?" verify-webhook)
     (guard who procedure? "procedure?" fetch-order))))

