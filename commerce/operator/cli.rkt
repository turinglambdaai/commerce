#lang racket/base

;; The operator CLI is a thin wrapper over commerce/operator — the module
;; is the whole implementation. `raco commerce find|explain|redrive` against
;; one service database path. Output is redacted by construction because the
;; underlying explanation carries canonical events and workflow state only.

(provide run-commerce-cli!)

(require file/sha1
         json
         racket/match
         racket/string
         "../operator.rkt"
         "../storage.rkt"
         "../storage/sqlite.rkt"
         "../private/model.rkt"
         "../private/storage-model.rkt")

(define (usage)
  (string-append
   "usage:\n"
   "  raco commerce find    <database> [pending|processing|completed]\n"
   "  raco commerce explain <database> <provider> <order-id>\n"
   "  raco commerce redrive <database> <idempotency-key>\n"))

(define (fail-usage!)
  ;; Automation must be able to parse a refusal as reliably as a success.
  (emit-json (hash 'error "invalid-arguments" 'usage (usage)))
  1)

(define (open-database path)
  (open-sqlite-commerce-storage path))

(define (emit-json value)
  (write-json value)
  (newline))

(define (outbox-item->json item)
  (hash 'id (issuance-outbox-item-id item)
        'idempotency-key (issuance-outbox-item-idempotency-key item)
        'action (symbol->string (issuance-outbox-item-action item))
        'provider (issuance-outbox-item-provider item)
        'order-id (issuance-outbox-item-order-id item)
        'offer-id (issuance-outbox-item-offer-id item)
        'subject-id (issuance-outbox-item-subject-id item)
        'status (symbol->string (issuance-outbox-item-status item))
        'attempts (issuance-outbox-item-attempts item)
        'available-at (issuance-outbox-item-available-at item)
        'last-error-code
        (let ([code (issuance-outbox-item-last-error-code item)])
          (if code (symbol->string code) 'null))
        'completed-at (or (issuance-outbox-item-completed-at item) 'null)))

(define (event->json event)
  (hash 'provider (payment-event-provider event)
        'event-id (payment-event-event-id event)
        'kind (symbol->string (payment-event-kind event))
        'order-id (payment-event-order-id event)
        'offer-id (payment-event-offer-id event)
        'subject-id (payment-event-subject-id event)
        'currency (money-currency (payment-event-amount event))
        'minor-units (money-minor-units (payment-event-amount event))
        'occurred-at (payment-event-occurred-at event)))

(define (credential->json record)
  (if record
      (hash 'entitlement-id (issued-credential-record-entitlement-id record)
            'revision (issued-credential-record-revision record)
            'credential-id (issued-credential-record-credential-id record)
            'key-id (issued-credential-record-key-id record)
            'envelope-digest
            (bytes->hex-string
             (sha256-bytes
              (issued-credential-record-envelope-bytes record))))
      'null))

(define (command-find database status)
  (define storage (open-database database))
  (define items
    (find-issuance-work storage
                        #:status (and status (string->symbol status))))
  (emit-json (map outbox-item->json items))
  (storage-close storage)
  0)

(define (command-explain database provider order-id)
  (define storage (open-database database))
  (define explanation (explain-order storage provider order-id))
  (define order (order-explanation-order explanation))
  (emit-json
   (hash 'order
         (if order
             (hash 'provider (order-projection-provider order)
                   'order-id (order-projection-order-id order)
                   'offer-id (order-projection-offer-id order)
                   'subject-id (order-projection-subject-id order)
                   'paid? (order-projection-paid? order)
                   'refunded? (order-projection-refunded? order))
             'null)
         'events (map event->json (order-explanation-events explanation))
         'work (map outbox-item->json (order-explanation-work explanation))
         'credentials (map credential->json
                            (order-explanation-credentials explanation))))
  (storage-close storage)
  0)

(define (command-redrive database idempotency-key)
  (define storage (open-database database))
  (with-handlers
      ([exn:fail:commerce?
        (lambda (failure)
          (emit-json
           (hash 'redriven #f
                 'code (symbol->string
                        (exn:fail:commerce-code failure))))
          (storage-close storage)
          1)])
    (define item
      (redrive-issuance-work! storage idempotency-key
                              #:now (current-seconds)))
    (emit-json (hash 'redriven #t
                     'available-at
                     (issuance-outbox-item-available-at item)))
    (storage-close storage)
    0))

;; Returns the process exit code: 0 on success, 1 on typed refusal or
;; usage error. Output is JSON on stdout; module `main` performs the exit.
(define (run-commerce-cli! arguments)
  (match arguments
    [(vector "find" database) (command-find database #f)]
    [(vector "find" database status)
     (if (member status '("pending" "processing" "completed"))
         (command-find database status)
         (fail-usage!))]
    [(vector "explain" database provider order-id)
     (command-explain database provider order-id)]
    [(vector "redrive" database key)
     (command-redrive database key)]
    [_ (fail-usage!)]))

(module+ main
  (exit (run-commerce-cli! (current-command-line-arguments))))
