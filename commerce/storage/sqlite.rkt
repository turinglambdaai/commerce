#lang racket/base

(provide open-sqlite-commerce-storage)

(require db
         racket/match
         "../private/journal-model.rkt"
         "../private/model.rkt"
         "../private/projection.rkt"
         "../private/storage-model.rkt")

(define schema-version 2)
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

(define select-next-unprojected-sql
  #<<SQL
SELECT j.sequence, j.provider, j.event_id, j.raw_payload, j.payload_digest,
       j.event_kind, j.order_id, j.offer_id, j.subject_id, j.currency,
       j.amount_minor_units, j.occurred_at, j.received_at
FROM commerce_event_journal AS j
LEFT JOIN commerce_projection_event AS p
  ON p.journal_sequence = j.sequence
WHERE p.journal_sequence IS NULL
ORDER BY j.sequence
LIMIT 1
SQL
  )

(define select-order-sql
  #<<SQL
SELECT provider, order_id, offer_id, subject_id, currency,
       amount_minor_units, paid, refunded, paid_at, refunded_at
FROM commerce_order_projection
WHERE provider = ? AND order_id = ?
SQL
  )

(define select-outbox-sql
  #<<SQL
SELECT id, idempotency_key, source_journal_sequence, action, provider,
       order_id, offer_id, subject_id, occurred_at, status, attempts,
       available_at, lease_owner, lease_expires_at, last_error_code,
       created_at, updated_at, completed_at
FROM commerce_issuance_outbox
WHERE idempotency_key = ?
SQL
  )

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (nullable value)
  (if (sql-null? value) #f value))

(define (sql-nullable value)
  (if value value sql-null))

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

(define (row->order row)
  (and row
       (match-let ([(vector provider order-id offer-id subject-id currency
                            amount-minor-units paid refunded paid-at refunded-at)
                    row])
         (order-projection
          provider order-id offer-id subject-id
          (money currency amount-minor-units)
          (= paid 1) (= refunded 1)
          (nullable paid-at) (nullable refunded-at)))))

(define (row->outbox row)
  (and row
       (match-let ([(vector id idempotency-key source-sequence action provider
                            order-id offer-id subject-id occurred-at status
                            attempts available-at lease-owner lease-expires-at
                            last-error-code created-at updated-at completed-at)
                    row])
         (issuance-outbox-item
          id idempotency-key source-sequence (string->symbol action)
          provider order-id offer-id subject-id occurred-at
          (string->symbol status) attempts available-at
          (nullable lease-owner) (nullable lease-expires-at)
          (and (not (sql-null? last-error-code))
               (string->symbol last-error-code))
          created-at updated-at (nullable completed-at)))))

(define (lookup-record connection provider event-id)
  (define row
    (query-maybe-row connection select-record-sql provider event-id))
  (and row (row->record row)))

(define (lookup-order connection provider order-id)
  (row->order
   (query-maybe-row connection select-order-sql provider order-id)))

(define (lookup-outbox connection idempotency-key)
  (row->outbox
   (query-maybe-row connection select-outbox-sql idempotency-key)))

(define (record-content=? record payload event)
  (and (equal? (journal-record-payload record) payload)
       (equal? (journal-record-event record) event)))

(define (check-sqlite-integer field value [event #f])
  (unless (<= value sqlite-max-integer)
    (raise-commerce
     'persistence-value-out-of-range
     "storage value exceeds SQLite's signed 64-bit integer range"
     (if event
         (hash 'provider (payment-event-provider event)
               'event-id (payment-event-event-id event)
               'field field)
         (hash 'field field)))))

(define (create-journal-schema! connection)
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
   ))

(define (create-projection-schema! connection)
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_order_projection (
  provider TEXT NOT NULL,
  order_id TEXT NOT NULL,
  offer_id TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  currency TEXT NOT NULL CHECK (length(currency) = 3),
  amount_minor_units INTEGER NOT NULL CHECK (amount_minor_units >= 0),
  paid INTEGER NOT NULL CHECK (paid IN (0, 1)),
  refunded INTEGER NOT NULL CHECK (refunded IN (0, 1)),
  paid_at INTEGER CHECK (paid_at >= 0),
  refunded_at INTEGER CHECK (refunded_at >= 0),
  last_event_sequence INTEGER NOT NULL,
  updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
  PRIMARY KEY (provider, order_id),
  FOREIGN KEY (last_event_sequence)
    REFERENCES commerce_event_journal(sequence),
  CHECK ((paid = 0 AND paid_at IS NULL) OR
         (paid = 1 AND paid_at IS NOT NULL)),
  CHECK ((refunded = 0 AND refunded_at IS NULL) OR
         (refunded = 1 AND refunded_at IS NOT NULL))
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_projection_event (
  journal_sequence INTEGER PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('projected', 'blocked')),
  failure_code TEXT,
  processed_at INTEGER NOT NULL CHECK (processed_at >= 0),
  FOREIGN KEY (journal_sequence)
    REFERENCES commerce_event_journal(sequence),
  CHECK ((status = 'projected' AND failure_code IS NULL) OR
         (status = 'blocked' AND failure_code IS NOT NULL))
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_issuance_outbox (
  id INTEGER PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  source_journal_sequence INTEGER NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('grant', 'withdraw')),
  provider TEXT NOT NULL,
  order_id TEXT NOT NULL,
  offer_id TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  occurred_at INTEGER NOT NULL CHECK (occurred_at >= 0),
  status TEXT NOT NULL
    CHECK (status IN ('pending', 'processing', 'completed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at INTEGER NOT NULL CHECK (available_at >= 0),
  lease_owner TEXT,
  lease_expires_at INTEGER CHECK (lease_expires_at >= 0),
  last_error_code TEXT,
  created_at INTEGER NOT NULL CHECK (created_at >= 0),
  updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
  completed_at INTEGER CHECK (completed_at >= 0),
  FOREIGN KEY (source_journal_sequence)
    REFERENCES commerce_event_journal(sequence),
  CHECK ((status = 'processing' AND lease_owner IS NOT NULL AND
          lease_expires_at IS NOT NULL) OR
         (status <> 'processing' AND lease_owner IS NULL AND
          lease_expires_at IS NULL)),
  CHECK ((status = 'completed' AND completed_at IS NOT NULL) OR
         (status <> 'completed' AND completed_at IS NULL))
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE INDEX commerce_issuance_outbox_ready
ON commerce_issuance_outbox(status, available_at, id)
SQL
   ))

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
        (create-journal-schema! connection)
        (create-projection-schema! connection)
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
    [(= stored-version 1)
     (call-with-transaction
      connection
      (lambda ()
        (create-projection-schema! connection)
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(not (= stored-version schema-version))
     (raise-commerce
      'unsupported-schema-version
      "Commerce storage schema version is unsupported"
      (hash 'expected schema-version 'actual stored-version))]))

(define (write-order! connection order journal-sequence processed-at)
  (query-exec
   connection
   #<<SQL
INSERT INTO commerce_order_projection
  (provider, order_id, offer_id, subject_id, currency, amount_minor_units,
   paid, refunded, paid_at, refunded_at, last_event_sequence, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(provider, order_id) DO UPDATE SET
  offer_id = excluded.offer_id,
  subject_id = excluded.subject_id,
  currency = excluded.currency,
  amount_minor_units = excluded.amount_minor_units,
  paid = excluded.paid,
  refunded = excluded.refunded,
  paid_at = excluded.paid_at,
  refunded_at = excluded.refunded_at,
  last_event_sequence = excluded.last_event_sequence,
  updated_at = excluded.updated_at
SQL
   (order-projection-provider order)
   (order-projection-order-id order)
   (order-projection-offer-id order)
   (order-projection-subject-id order)
   (money-currency (order-projection-amount order))
   (money-minor-units (order-projection-amount order))
   (if (order-projection-paid? order) 1 0)
   (if (order-projection-refunded? order) 1 0)
   (sql-nullable (order-projection-paid-at order))
   (sql-nullable (order-projection-refunded-at order))
   journal-sequence
   processed-at))

(define (write-outbox! connection intent journal-sequence processed-at)
  (query-exec
   connection
   #<<SQL
INSERT INTO commerce_issuance_outbox
  (idempotency_key, source_journal_sequence, action, provider, order_id,
   offer_id, subject_id, occurred_at, status, attempts, available_at,
   lease_owner, lease_expires_at, last_error_code, created_at, updated_at,
   completed_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, NULL, NULL, NULL, ?, ?, NULL)
SQL
   (rights-intent-idempotency-key intent)
   journal-sequence
   (symbol->string (rights-intent-action intent))
   (rights-intent-provider intent)
   (rights-intent-order-id intent)
   (rights-intent-offer-id intent)
   (rights-intent-subject-id intent)
   (rights-intent-occurred-at intent)
   processed-at processed-at processed-at)
  (lookup-outbox connection (rights-intent-idempotency-key intent)))

(define (open-sqlite-commerce-storage database)
  (unless (path-string? database)
    (raise-argument-error
     'open-sqlite-commerce-storage "path-string?" database))
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
    ;; FULL makes a successful journal or projector commit the durability
    ;; boundary. Foreign keys protect cross-table source sequence references.
    (query-value connection "PRAGMA journal_mode = WAL")
    (query-exec connection "PRAGMA synchronous = FULL")
    (query-exec connection "PRAGMA foreign_keys = ON")
    (initialize-schema! connection))

  (define closed? (box #f))

  (define (check-open)
    (when (unbox closed?)
      (raise-commerce 'storage-closed "commerce storage is closed" (hash))))

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

  (define (lookup-journal provider event-id)
    (check-open)
    (lookup-record connection provider event-id))

  (define (project-next processed-at)
    (check-open)
    (check-sqlite-integer 'processed-at processed-at)
    (call-with-transaction
     connection
     (lambda ()
       (define row (query-maybe-row connection select-next-unprojected-sql))
       (cond
         [(not row) #f]
         [else
          (define record (row->record row))
          (define sequence (journal-record-sequence record))
          (define event (journal-record-event record))
          (define previous
            (lookup-order connection
                          (payment-event-provider event)
                          (payment-event-order-id event)))
          (with-handlers
              ([exn:fail:commerce?
                (lambda (failure)
                  (if (eq? (exn:fail:commerce-code failure) 'order-conflict)
                      (begin
                        (query-exec
                         connection
                         #<<SQL
INSERT INTO commerce_projection_event
  (journal_sequence, status, failure_code, processed_at)
VALUES (?, 'blocked', 'order-conflict', ?)
SQL
                         sequence processed-at)
                        (projection-result
                         'blocked sequence previous '() 'order-conflict))
                      (raise failure)))])
            (define-values (next-order intents)
              (project-order-event previous event))
            (write-order! connection next-order sequence processed-at)
            (define outbox-items
              (for/list ([intent (in-list intents)])
                (write-outbox! connection intent sequence processed-at)))
            (query-exec
             connection
             #<<SQL
INSERT INTO commerce_projection_event
  (journal_sequence, status, failure_code, processed_at)
VALUES (?, 'projected', NULL, ?)
SQL
             sequence processed-at)
            (projection-result
             'projected sequence next-order outbox-items #f))]))
     #:option 'immediate))

  (define (lookup-projection provider order-id)
    (check-open)
    (lookup-order connection provider order-id))

  (define (lookup-work idempotency-key)
    (check-open)
    (lookup-outbox connection idempotency-key))

  (define (close)
    (unless (unbox closed?)
      (disconnect connection)
      (set-box! closed? #t)))

  (commerce-storage
   accept lookup-journal project-next lookup-projection lookup-work close))
