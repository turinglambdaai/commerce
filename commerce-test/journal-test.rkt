#lang racket/base

(require commerce
         commerce/journal
         commerce/journal/sqlite
         commerce/provider
         db
         file/sha1
         rackunit
         racket/file)

(define usd-29 (money "USD" 2900))

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

(define (event payload
               #:event-id [event-id "evt_001"]
               #:offer [offer-id "taskly-pro-lifetime"]
               #:subject [subject-id "customer-001"])
  (make-verified-payment-event
   "mock"
   event-id
   (payload-digest payload)
   'payment-succeeded
   "ord_001"
   offer-id
   subject-id
   usd-29
   1792108800))

(define (delete-if-present path)
  (when (file-exists? path)
    (delete-file path)))

(define (call-with-temporary-database proc)
  (define path (make-temporary-file "commerce-journal-~a.sqlite"))
  (delete-file path)
  (dynamic-wind
    void
    (lambda () (proc path))
    (lambda ()
      (for ([suffix '("" "-shm" "-wal")])
        (delete-if-present
         (string->path (string-append (path->string path) suffix)))))))

(test-case "accepted event is durable and its emitted row is exact"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"{\"id\":\"evt_001\",\"paid\":true}")
     (define accepted-event (event payload))
     (define journal (open-sqlite-event-journal path))
     (define result
       (journal-accept! journal payload accepted-event #:received-at 1792108810))
     (check-eq? (journal-acceptance-disposition result) 'accepted)
     (check-equal? (journal-record-sequence
                    (journal-acceptance-record result))
                   1)
     (journal-close journal)

     ;; A fresh connection proves the acknowledgement was returned only after
     ;; the row survived the original connection.
     (define reopened (open-sqlite-event-journal path))
     (define record (journal-ref reopened "mock" "evt_001"))
     (check-equal? (journal-record-payload record) payload)
     (check-equal? (journal-record-event record) accepted-event)
     (check-equal? (journal-record-received-at record) 1792108810)
     (journal-close reopened)

     ;; Inspect the persistence artifact, not only the public wrapper.
     (define connection
       (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-row
       connection
       #<<SQL
SELECT provider, event_id, raw_payload, payload_digest, event_kind,
       order_id, offer_id, subject_id, currency, amount_minor_units,
       occurred_at, received_at
FROM commerce_event_journal
WHERE provider = 'mock' AND event_id = 'evt_001'
SQL
       )
      (vector "mock" "evt_001" payload (payload-digest payload)
              "payment-succeeded" "ord_001" "taskly-pro-lifetime"
              "customer-001" "USD" 2900 1792108800 1792108810))
     (disconnect connection))))

(test-case "exact replay returns the original row without appending"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"same authenticated request")
     (define accepted-event (event payload))
     (define journal (open-sqlite-event-journal path))
     (define first
       (journal-accept! journal payload accepted-event #:received-at 10))
     (journal-close journal)

     ;; Provider retries remain idempotent across service restarts.
     (define reopened (open-sqlite-event-journal path))
     (define replay
       (journal-accept! reopened payload accepted-event #:received-at 20))
     (check-eq? (journal-acceptance-disposition first) 'accepted)
     (check-eq? (journal-acceptance-disposition replay) 'replayed)
     (check-equal? (journal-record-sequence
                    (journal-acceptance-record replay))
                   1)
     (check-equal? (journal-record-received-at
                    (journal-acceptance-record replay))
                   10)
     (journal-close reopened)

     (define connection
       (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_event_journal")
      1)
     (disconnect connection))))

(test-case "same event key with changed authenticated content fails closed"
  (call-with-temporary-database
   (lambda (path)
     (define first-payload #"first")
     (define changed-payload #"changed")
     (define journal (open-sqlite-event-journal path))
     (journal-accept! journal first-payload (event first-payload)
                      #:received-at 10)
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure) 'event-conflict)))
      (lambda ()
        (journal-accept! journal changed-payload (event changed-payload)
                         #:received-at 20)))
     (define record (journal-ref journal "mock" "evt_001"))
     (check-equal? (journal-record-payload record) first-payload)
     (journal-close journal))))

(test-case "same raw payload with changed canonical meaning fails closed"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"one authenticated request")
     (define journal (open-sqlite-event-journal path))
     (journal-accept! journal payload (event payload) #:received-at 10)
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure) 'event-conflict)))
      (lambda ()
        (journal-accept! journal payload
                         (event payload #:subject "customer-002")
                         #:received-at 20)))
     (journal-close journal))))

(test-case "payload digest mismatch is rejected without a row"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated body")
     (define journal (open-sqlite-event-journal path))
     (define mismatched
       (make-verified-payment-event
        "mock" "evt_001" (make-string 64 #\a) 'payment-succeeded
        "ord_001" "taskly-pro-lifetime" "customer-001" usd-29 1792108800))
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure)
                  'payload-digest-mismatch)))
      (lambda ()
        (journal-accept! journal payload mismatched #:received-at 10)))
     (check-false (journal-ref journal "mock" "evt_001"))
     (journal-close journal))))

(test-case "database rejects mutation and deletion of accepted evidence"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"immutable authenticated request")
     (define journal (open-sqlite-event-journal path))
     (journal-accept! journal payload (event payload) #:received-at 10)
     (journal-close journal)

     (define connection
       (sqlite3-connect #:database path #:mode 'read/write))
     (check-exn
      exn:fail:sql?
      (lambda ()
        (query-exec
         connection
         "UPDATE commerce_event_journal SET received_at = 20")))
     (check-exn
      exn:fail:sql?
      (lambda ()
        (query-exec connection "DELETE FROM commerce_event_journal")))
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_event_journal")
      1)
     (disconnect connection))))

(test-case "caller mutation cannot change accepted raw bytes"
  (call-with-temporary-database
   (lambda (path)
     (define payload (bytes 1 2 3 4))
     (define accepted-event (event payload))
     (define journal (open-sqlite-event-journal path))
     (journal-accept! journal payload accepted-event #:received-at 10)
     (bytes-set! payload 0 255)
     (check-equal?
      (journal-record-payload (journal-ref journal "mock" "evt_001"))
      (bytes->immutable-bytes (bytes 1 2 3 4)))
     (journal-close journal))))
