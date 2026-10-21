#lang racket/base

(provide
 commerce-log-event?
 commerce-log-event-level
 commerce-log-event-code
 commerce-log-event-correlation
 commerce-log-event-fields
 commerce-log-event-at
 log-commerce-event!
 commerce-logger)

(require racket/logging
         "private/model.rkt")

;; Structured, redacted-by-construction event logging. Every record is a
;; typed event whose fields are correlation identifiers and workflow state
;; only — never raw provider bytes, claim tokens, signing keys, or customer
;; contact data. Transport formatting (JSON lines, shipping) belongs to the
;; deployment, not to this boundary.
(struct commerce-log-event
  (level code correlation fields at)
  #:transparent)

(define-logger commerce)

;; Correlation is key-whitelisted so no future call site can smuggle a
;; token, subject key, or payload field into the correlation slot.
(define correlation-keys
  '(provider event-id order-id subject-id offer-id idempotency-key
    outbox-id entitlement-id credential-id claim-id revision policy-id
    sequence))

(define (correlation-identifier? value)
  (or (string? value)
      (exact-nonnegative-integer? value)
      (not value)))

;; Field values are redaction-safe scalars: strings, exact integers,
;; booleans, and kebab-case symbols (workflow states and typed error
;; codes). Bytes, lists, hashes, and non-kebab symbols never pass.
(define whitelisted-values
  '(grant withdraw pending processing completed ready claimed expired
    accepted replayed projected blocked released lease-lost fulfilled
    notified))

(define (redacted-field? value)
  (or (string? value)
      (exact-integer? value)
      (boolean? value)
      (and (symbol? value)
           (or (memq value whitelisted-values)
               (stable-id? (symbol->string value))))))

(define (log-commerce-event! level code correlation fields)
  (unless (member level '(debug info warning error))
    (raise-argument-error 'log-commerce-event! "(member level '(debug info warning error))" level))
  (unless (symbol? code)
    (raise-argument-error 'log-commerce-event! "symbol?" code))
  (unless (and (hash? correlation)
               (for/and ([(k v) (in-hash correlation)])
                 (and (memq k correlation-keys)
                      (correlation-identifier? v))))
    (raise-argument-error
     'log-commerce-event!
     (format "hash of whitelisted keys ~a with string/integer/#f values"
             correlation-keys)
     correlation))
  (unless (and (hash? fields)
               (for/and ([(k v) (in-hash fields)])
                 (and (symbol? k) (redacted-field? v))))
    (raise-argument-error
     'log-commerce-event!
     "hash of symbol keys with whitelisted scalar values"
     fields))
  (when (log-level? commerce-logger level)
    (log-message commerce-logger level "commerce-event"
                 (commerce-log-event
                  level code correlation fields (current-seconds)))))
