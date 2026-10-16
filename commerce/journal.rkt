#lang racket/base

(provide
 event-journal?
 journal-record?
 journal-record-sequence
 journal-record-event
 journal-record-payload
 journal-record-received-at
 journal-acceptance?
 journal-acceptance-disposition
 journal-acceptance-record
 journal-accept!
 journal-ref
 journal-close)

(require file/sha1
         "private/journal-model.rkt"
         "private/model.rkt")

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (check-journal who journal)
  (unless (event-journal? journal)
    (raise-argument-error who "event-journal?" journal)))

;; A provider adapter may request acknowledgement only through this operation.
;; The raw bytes are copied before hashing so caller mutation cannot make the
;; digest check and the committed value disagree.
(define (journal-accept! journal payload event #:received-at received-at)
  (check-journal 'journal-accept! journal)
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
  ((event-journal-accept journal) immutable-payload event received-at))

(define (journal-ref journal provider event-id)
  (check-journal 'journal-ref journal)
  (unless (stable-id? provider)
    (raise-argument-error
     'journal-ref "stable kebab-case provider identifier" provider))
  (unless (opaque-id? event-id)
    (raise-argument-error
     'journal-ref "non-empty opaque provider event identifier" event-id))
  ((event-journal-lookup journal) provider event-id))

(define (journal-close journal)
  (check-journal 'journal-close journal)
  ((event-journal-close journal)))
