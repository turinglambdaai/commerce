#lang racket/base

(provide
 commerce-storage?
 projection-result?
 projection-result-disposition
 projection-result-journal-sequence
 projection-result-order
 projection-result-outbox
 projection-result-failure-code
 issuance-outbox-item?
 issuance-outbox-item-id
 issuance-outbox-item-idempotency-key
 issuance-outbox-item-source-sequence
 issuance-outbox-item-action
 issuance-outbox-item-provider
 issuance-outbox-item-order-id
 issuance-outbox-item-offer-id
 issuance-outbox-item-subject-id
 issuance-outbox-item-occurred-at
 issuance-outbox-item-status
 issuance-outbox-item-attempts
 issuance-outbox-item-available-at
 issuance-outbox-item-lease-owner
 issuance-outbox-item-lease-expires-at
 issuance-outbox-item-last-error-code
 issuance-outbox-item-created-at
 issuance-outbox-item-updated-at
 issuance-outbox-item-completed-at
 storage-project-next!
 storage-order-ref
 storage-outbox-ref
 storage-close)

(require "private/model.rkt"
         "private/storage-model.rkt")

(define (check-storage who storage)
  (unless (commerce-storage? storage)
    (raise-argument-error who "commerce-storage?" storage)))

(define (storage-project-next! storage #:processed-at processed-at)
  (check-storage 'storage-project-next! storage)
  (unless (exact-nonnegative-integer? processed-at)
    (raise-argument-error
     'storage-project-next! "exact-nonnegative-integer?" processed-at))
  ((commerce-storage-project-next storage) processed-at))

(define (storage-order-ref storage provider order-id)
  (check-storage 'storage-order-ref storage)
  (unless (stable-id? provider)
    (raise-argument-error
     'storage-order-ref "stable kebab-case provider identifier" provider))
  (unless (opaque-id? order-id)
    (raise-argument-error
     'storage-order-ref "non-empty opaque provider order identifier" order-id))
  ((commerce-storage-order-lookup storage) provider order-id))

(define (storage-outbox-ref storage idempotency-key)
  (check-storage 'storage-outbox-ref storage)
  (unless (and (string? idempotency-key)
               (<= 1 (string-length idempotency-key) 512))
    (raise-argument-error
     'storage-outbox-ref "non-empty idempotency key up to 512 characters"
     idempotency-key))
  ((commerce-storage-outbox-lookup storage) idempotency-key))

(define (storage-close storage)
  (check-storage 'storage-close storage)
  ((commerce-storage-close storage)))
