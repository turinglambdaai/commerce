#lang racket/base

(provide
 journal-record?
 journal-record-sequence
 journal-record-event
 journal-record-payload
 journal-record-received-at
 journal-acceptance?
 journal-acceptance-disposition
 journal-acceptance-record
 journal-accept!
 journal-ref)

(require file/sha1
         "private/journal-model.rkt"
         "private/model.rkt"
         "private/storage-model.rkt")

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (check-storage who storage)
  (unless (commerce-storage? storage)
    (raise-argument-error who "commerce-storage?" storage)))

;; A provider adapter may request acknowledgement only through this operation.
;; The raw bytes are copied before hashing so caller mutation cannot make the
;; digest check and the committed value disagree.
(define (journal-accept! storage payload event #:received-at received-at)
  (check-storage 'journal-accept! storage)
  (unless (bytes? payload)
    (raise-argument-error 'journal-accept! "bytes?" payload))
  (unless (payment-event? event)
    (raise-argument-error 'journal-accept! "payment-event?" event))
  (unless (exact-nonnegative-integer? received-at)
    (raise-argument-error
     'journal-accept! "exact-nonnegative-integer?" received-at))
  (define immutable-payload (bytes->immutable-bytes payload))
  (define actual-digest
    (bytes->hex-string (sha256-bytes immutable-payload)))
  (unless (string=? actual-digest (payment-event-payload-digest event))
    (raise-commerce
     'payload-digest-mismatch
     "authenticated raw payload does not match the canonical event digest"
     (hash 'provider (payment-event-provider event)
           'event-id (payment-event-event-id event)
           'expected (payment-event-payload-digest event)
           'actual actual-digest)))
  ((commerce-storage-journal-accept storage)
   immutable-payload event received-at))

(define (journal-ref storage provider event-id)
  (check-storage 'journal-ref storage)
  (unless (stable-id? provider)
    (raise-argument-error
     'journal-ref "stable kebab-case provider identifier" provider))
  (unless (opaque-id? event-id)
    (raise-argument-error
     'journal-ref "non-empty opaque provider event identifier" event-id))
  ((commerce-storage-journal-lookup storage) provider event-id))
