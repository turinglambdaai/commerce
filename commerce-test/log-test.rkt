#lang racket/base

(require commerce
         commerce/journal
         commerce/log
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         file/sha1
         rackunit
         racket/contract
         racket/file
         racket/logging
         racket/match)

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

;; One unique directory per database so rapid calls never share a path.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-log-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (next-log-event receiver)
  (match-define (vector _level _message data _topic)
    (sync receiver))
  data)

(test-case "log events are structured and redacted by construction"
  ;; A receiver's level raises the logger's own level, so create it first.
  (define receiver (make-log-receiver commerce-logger 'debug))
  (log-commerce-event!
   'info 'journal-accepted
   (hash 'provider "mock" 'event-id "evt_001" 'order-id "ord_001")
   (hash 'kind 'payment-succeeded 'sequence 1))
  (define event (next-log-event receiver))
  (check-eq? (commerce-log-event-level event) 'info)
  (check-eq? (commerce-log-event-code event) 'journal-accepted)
  (check-equal? (commerce-log-event-correlation event)
                (hash 'provider "mock" 'event-id "evt_001"
                      'order-id "ord_001"))
  (check-equal? (commerce-log-event-fields event)
                (hash 'kind 'payment-succeeded 'sequence 1))
  (check-true (exact-nonnegative-integer?
               (commerce-log-event-at event)))
  (check-exn
   exn:fail:contract?
   (lambda ()
     ;; Raw provider bytes are not a loggable field value.
     (log-commerce-event!
      'info 'journal-accepted (hash 'provider "mock")
      (hash 'raw-payload #"\"secret\"")))
   "raw bytes must be rejected as a field value")
  (check-exn
   exn:fail:contract?
   (lambda ()
     ;; Claim tokens are correlation-forbidden too.
     (log-commerce-event!
      'info 'claim-fulfilled (hash 'claim-token "tok-secret") (hash)))
   "tokens must be rejected as a correlation value"))

(test-case "journal operations emit correlatable events without raw bytes"
  (call-with-temporary-database
   (lambda (path)
     (define receiver (make-log-receiver commerce-logger 'info))
     (define payload #"authenticated payment bytes")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept!
      storage payload
      (make-verified-payment-event
       "mock" "evt_001" (payload-digest payload) 'payment-succeeded
       "ord_001" "taskly-pro-lifetime" "customer-001"
       (money "USD" 2900) 1792108800)
      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define accepted
       (or (let ([received (sync/timeout 10 receiver)])
             (and received (vector-ref received 2)))
           (fail "no journal-accepted event within 10 seconds")))
     (check-eq? (commerce-log-event-code accepted) 'journal-accepted)
     (check-equal?
      (hash-ref (commerce-log-event-correlation accepted) 'order-id)
      "ord_001")
     (define projected
       (or (let ([received (sync/timeout 10 receiver)])
             (and received (vector-ref received 2)))
           (fail "no projection-projected event within 10 seconds")))
     (check-eq? (commerce-log-event-code projected) 'projection-projected)
     (check-equal?
      (hash-ref (commerce-log-event-fields projected) 'work)
      1)
     ;; An exact replay logs at debug, below the info receiver.
     (journal-accept!
      storage payload
      (make-verified-payment-event
       "mock" "evt_001" (payload-digest payload) 'payment-succeeded
       "ord_001" "taskly-pro-lifetime" "customer-001"
       (money "USD" 2900) 1792108800)
      #:received-at 12)
     (check-false
      (sync/timeout 0 receiver)
      "replays are logged at debug and must not appear on an info receiver")
     (storage-close storage))))
