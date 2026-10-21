#lang racket/base

(provide
 order-explanation?
 order-explanation-order
 order-explanation-events
 order-explanation-work
 order-explanation-credentials
 find-issuance-work
 explain-order
 redrive-issuance-work!)

(require racket/list
         "journal.rkt"
         "storage.rkt"
         "private/model.rkt"
         "private/storage-model.rkt")

;; The operator surface answers "a customer says they paid" without exposing
;; raw provider bytes. Explanations carry canonical event snapshots, order
;; projections, workflow state, and delivery evidence; deep journal payload
;; access stays behind commerce/journal for explicit diagnosis.

(struct order-explanation
  (order events work credentials)
  #:transparent)

(define (find-issuance-work storage #:status [status #f])
  (unless (commerce-storage? storage)
    (raise-argument-error 'find-issuance-work "commerce-storage?" storage))
  (when status
    (unless (member status '(pending processing completed))
      (raise-argument-error
       'find-issuance-work "(or/c 'pending 'processing 'completed #f)"
       status)))
  (storage-outbox-scan storage #:status status))

(define (explain-order storage provider order-id)
  (unless (commerce-storage? storage)
    (raise-argument-error 'explain-order "commerce-storage?" storage))
  (unless (stable-id? provider)
    (raise-argument-error
     'explain-order "stable kebab-case provider identifier" provider))
  (unless (opaque-id? order-id)
    (raise-argument-error
     'explain-order "non-empty opaque provider order identifier" order-id))
  (define work
    (storage-order-outbox storage provider order-id))
  (order-explanation
   (storage-order-ref storage provider order-id)
   (map journal-record-event
        (storage-order-journal storage provider order-id))
   work
   (map (lambda (item)
          (storage-issued-credential-ref
           storage (issuance-outbox-item-id item)))
        work)))

;; Replay always reuses the immutable journal through the normal projection
;; path; redrive only makes already-pending issuance work due again. Neither
;; edits a projection row or rewinds completed work.
(define (redrive-issuance-work! storage idempotency-key #:now now)
  (unless (commerce-storage? storage)
    (raise-argument-error
     'redrive-issuance-work! "commerce-storage?" storage))
  (unless (and (string? idempotency-key)
               (<= 1 (string-length idempotency-key) 512))
    (raise-argument-error
     'redrive-issuance-work!
     "non-empty idempotency key up to 512 characters" idempotency-key))
  (unless (exact-nonnegative-integer? now)
    (raise-argument-error
     'redrive-issuance-work! "exact-nonnegative-integer?" now))
  (storage-redrive-issuance-work! storage idempotency-key #:now now))
