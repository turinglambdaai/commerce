#lang racket/base

(provide open-sqlite-event-journal)

(require db
         racket/match
         "../private/journal-model.rkt"
         "../private/model.rkt")

(define schema-version 1)
(define application-id 1129270605) ; ASCII "COMM"
(define sqlite-max-integer 9223372036854775807)

(define select-record-sql
  #<<SQL
SELECT sequence, provider, event_id, raw_payload, payload_digest, event_kind,
       order_id, offer_id, subject_id, currency, amount_minor_units,
       occurred_at, received_at
FROM commerce_event_journal
WHERE provider = ? AND event_id = ?
SQL
  )

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (row->record row)
  (match-define
    (vector sequence provider event-id payload payload-digest event-kind
            order-id offer-id subject-id currency amount-minor-units
            occurred-at received-at)
    row)
  (journal-record
   sequence
   (payment-event provider event-id payload-digest
                  (string->symbol event-kind)
                  order-id offer-id subject-id
                  (money currency amount-minor-units)
                  occurred-at)
   (bytes->immutable-bytes payload)
   received-at))

(define (lookup-record connection provider event-id)
  (define row
    (query-maybe-row connection select-record-sql provider event-id))
  (and row (row->record row)))

(define (record-content=? record payload event)
  (and (equal? (journal-record-payload record) payload)
       (equal? (journal-record-event record) event)))

(define (check-sqlite-integer field value event)
  (unless (<= value sqlite-max-integer)
    (raise-commerce
     'persistence-value-out-of-range
     "journal value exceeds SQLite's signed 64-bit integer range"
     (hash 'provider (payment-event-provider event)
           'event-id (payment-event-event-id event)
           'field field))))

(define (initialize-schema! connection)
  (define stored-application-id
    (query-value connection "PRAGMA application_id"))
  (define stored-version
    (query-value connection "PRAGMA user_version"))
  (cond
    [(and (= stored-application-id 0) (= stored-version 0))
     (call-with-transaction
      connection
      (lambda ()
        (query-exec
         connection
         #<<SQL
CREATE TABLE commerce_event_journal (
  sequence INTEGER PRIMARY KEY,
  provider TEXT NOT NULL,
  event_id TEXT NOT NULL,
  raw_payload BLOB NOT NULL,
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  event_kind TEXT NOT NULL
    CHECK (event_kind IN ('payment-succeeded', 'payment-refunded')),
  order_id TEXT NOT NULL,
  offer_id TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  currency TEXT NOT NULL CHECK (length(currency) = 3),
  amount_minor_units INTEGER NOT NULL CHECK (amount_minor_units >= 0),
  occurred_at INTEGER NOT NULL CHECK (occurred_at >= 0),
  received_at INTEGER NOT NULL CHECK (received_at >= 0),
  UNIQUE (provider, event_id)
)
SQL
         )
        (query-exec
         connection
         #<<SQL
CREATE TRIGGER commerce_event_journal_no_update
BEFORE UPDATE ON commerce_event_journal
BEGIN
  SELECT RAISE(ABORT, 'commerce event journal rows are immutable');
END
SQL
         )
        (query-exec
         connection
         #<<SQL
CREATE TRIGGER commerce_event_journal_no_delete
BEFORE DELETE ON commerce_event_journal
BEGIN
  SELECT RAISE(ABORT, 'commerce event journal rows are immutable');
END
SQL
         )
        (query-exec connection
                    (format "PRAGMA application_id = ~a" application-id))
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(not (= stored-application-id application-id))
     (raise-commerce
      'database-identity-conflict
      "SQLite database does not belong to Commerce"
      (hash 'application-id stored-application-id))]
    [(not (= stored-version schema-version))
     (raise-commerce
      'unsupported-schema-version
      "Commerce journal schema version is unsupported"
      (hash 'expected schema-version 'actual stored-version))]))

(define (open-sqlite-event-journal database)
  (unless (path-string? database)
    (raise-argument-error
     'open-sqlite-event-journal "path-string?" database))
  (define connection
    (sqlite3-connect
     #:database database
     #:mode 'create
     #:busy-retry-delay 0.05
     #:busy-retry-limit 40))
  (with-handlers ([exn?
                   (lambda (failure)
                     (disconnect connection)
                     (raise failure))])
    ;; FULL synchronous mode makes a successful commit the acknowledgement
    ;; boundary. WAL keeps readers from blocking the single journal writer.
    (query-value connection "PRAGMA journal_mode = WAL")
    (query-exec connection "PRAGMA synchronous = FULL")
    (initialize-schema! connection))

  (define closed? (box #f))

  (define (check-open)
    (when (unbox closed?)
      (raise-commerce 'journal-closed "event journal is closed" (hash))))

  (define (accept payload event received-at)
    (check-open)
    (check-sqlite-integer
     'amount-minor-units (money-minor-units (payment-event-amount event)) event)
    (check-sqlite-integer 'occurred-at (payment-event-occurred-at event) event)
    (check-sqlite-integer 'received-at received-at event)
    (call-with-transaction
     connection
     (lambda ()
       (define existing
         (lookup-record connection
                        (payment-event-provider event)
                        (payment-event-event-id event)))
       (cond
         [existing
          (if (record-content=? existing payload event)
              (journal-acceptance 'replayed existing)
              (raise-commerce
               'event-conflict
               "provider event id was replayed with different content"
               (hash 'provider (payment-event-provider event)
                     'event-id (payment-event-event-id event)
                     'persisted-sequence
                     (journal-record-sequence existing))))]
         [else
          (query-exec
           connection
           #<<SQL
INSERT INTO commerce_event_journal
  (provider, event_id, raw_payload, payload_digest, event_kind, order_id,
   offer_id, subject_id, currency, amount_minor_units, occurred_at, received_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
           (payment-event-provider event)
           (payment-event-event-id event)
           payload
           (payment-event-payload-digest event)
           (symbol->string (payment-event-kind event))
           (payment-event-order-id event)
           (payment-event-offer-id event)
           (payment-event-subject-id event)
           (money-currency (payment-event-amount event))
           (money-minor-units (payment-event-amount event))
           (payment-event-occurred-at event)
           received-at)
          (journal-acceptance
           'accepted
           (lookup-record connection
                          (payment-event-provider event)
                          (payment-event-event-id event)))]))
     #:option 'immediate))

  (define (lookup provider event-id)
    (check-open)
    (lookup-record connection provider event-id))

  (define (close)
    (unless (unbox closed?)
      (disconnect connection)
      (set-box! closed? #t)))

  (event-journal accept lookup close))
