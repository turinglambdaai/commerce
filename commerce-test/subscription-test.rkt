#lang racket/base

(require commerce
         commerce/issuer
         commerce/journal
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         db
         file/sha1
         json
         permit/issuer
         rackunit
         racket/file
         racket/port)

(define usd-999 (money "USD" 99900))

(define taskly-subscription
  (offer "taskly-pro-monthly" "taskly" 'subscription usd-999
         "taskly-pro-v1"))

(define taskly-policy
  (make-permit-entitlement-policy
   "taskly-pro-v1" 1
   #:subject-type 'person
   #:grants (list (make-permit-grant-policy #:products '("taskly")))))

(define catalog
  (make-permit-policy-catalog
   (list taskly-subscription) (list taskly-policy)))

(define issuer-name "com.turinglambdaai")
(define key-id "test-2026")

(define-values (private-key public-key) (generate-ed25519-keypair))

(define trust-store
  (jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1
           'issuer issuer-name
           'keys
           (hasheq 'test-2026
                   (hasheq 'algorithm "Ed25519"
                           'public_key (public-key->base64 public-key)
                           'status "active"
                           'purposes '("entitlement")
                           'not_before 'null
                           'not_after 'null)))))

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

(define (event payload
               #:event-id [event-id "evt_001"]
               #:kind [kind 'payment-succeeded]
               #:paid-through [paid-through #f]
               #:occurred-at [occurred-at 1792108800])
  (make-verified-payment-event
   "mock" event-id (payload-digest payload) kind "ord_sub_001"
   "taskly-pro-monthly" "customer-001" usd-999 occurred-at
   #:paid-through paid-through))

;; One unique directory per database so rapid calls never share a path.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-subscription-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (worker clock-epoch)
  (make-issuance-worker
   #:catalog catalog
   #:issuer issuer-name
   #:private-key private-key
   #:key-id key-id
   #:trust-store trust-store
   #:clock (lambda () (values clock-epoch "2026-10-21T00:00:00Z"))))

(define (rfc3339-for epoch-seconds)
  (define moment (seconds->date epoch-seconds #t))
  (define (pad2 value)
    (if (< value 10) (string-append "0" (number->string value))
        (number->string value)))
  (string-append
   (number->string (date-year moment))
   "-" (pad2 (date-month moment))
   "-" (pad2 (date-day moment))
   "T" (pad2 (date-hour moment))
   ":" (pad2 (date-minute moment))
   ":" (pad2 (date-second moment)) "Z"))

(define (count-revisions path)
  (define connection (sqlite3-connect #:database path #:mode 'read-only))
  (begin0
    (query-value connection "SELECT COUNT(*) FROM commerce_entitlement_revision")
    (disconnect connection)))

(test-case "a subscription payment extends paid-through and grants once"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"first period paid")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept!
      storage payload
      (event payload #:paid-through 1794694400)
      #:received-at 10)
     (define first
       (storage-project-next! storage #:processed-at 11))
     (check-equal? (length (projection-result-outbox first)) 1)
     (define order (projection-result-order first))
     (check-equal? (order-projection-paid-through order) 1794694400)
     (check-equal?
      (issuance-outbox-item-idempotency-key
       (car (projection-result-outbox first)))
      "mock/ord_sub_001/renewal/1794694400")
     (define grant-result
       (process-issuance-work! (worker 100) storage))
     (check-eq? (issuance-result-disposition grant-result) 'completed)
     (check-equal? (issuance-result-revision grant-result) 0)
     ;; A redelivered renewal for the same window emits no new work.
     (check-false (storage-project-next! storage #:processed-at 12))
     ;; The next period's renewal extends the window and emits exactly one
     ;; keyed intent.
     (define next-payload #"second period paid")
     (journal-accept!
      storage next-payload
      (event next-payload #:event-id "evt_002"
             #:paid-through 1797372800)
      #:received-at 20)
     (define second
       (storage-project-next! storage #:processed-at 21))
     (check-equal? (length (projection-result-outbox second)) 1)
     (check-equal?
      (issuance-outbox-item-idempotency-key
       (car (projection-result-outbox second)))
      "mock/ord_sub_001/renewal/1797372800")
     (define renewal-result
       (process-issuance-work! (worker 200) storage))
     (check-eq? (issuance-result-disposition renewal-result) 'completed)
     (check-equal? (issuance-result-revision renewal-result) 1)
     (define revision
       (issuance-completion-revision
        (issuance-result-completion renewal-result)))
     (check-equal? (entitlement-revision-previous-revision revision) 0)
     (define successor
       (with-input-from-bytes
           (entitlement-revision-payload-bytes revision)
         read-json))
     (check-equal? (hash-ref successor 'revision) 1)
     (check-equal?
      (hash-ref (hash-ref successor 'constraints) 'use_expires_at)
      (rfc3339-for 1797372800))
     (storage-close storage)
     (check-equal? (count-revisions path) 2))))

(test-case "a late renewal never shrinks the paid-through window"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-sqlite-commerce-storage path))
     (define payload #"period one")
     (journal-accept!
      storage payload (event payload #:paid-through 1797372800)
      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (process-issuance-work! (worker 100) storage)
     (define late-payload #"late period two")
     (journal-accept!
      storage late-payload
      (event late-payload #:event-id "evt_late"
             #:paid-through 1794694400)
      #:received-at 20)
     (define result (storage-project-next! storage #:processed-at 21))
     (check-equal? (length (projection-result-outbox result)) 0)
     (check-equal?
      (order-projection-paid-through (projection-result-order result))
      1797372800)
     (storage-close storage)
     (check-equal? (count-revisions path) 1))))

(test-case "cancellation refunds expire the successor at period end"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-sqlite-commerce-storage path))
     (define payload #"period one")
     (journal-accept!
      storage payload (event payload #:paid-through 1794694400)
      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (process-issuance-work! (worker 100) storage)
     (define refund-payload #"cancelled and refunded")
     (journal-accept!
      storage refund-payload
      (event refund-payload #:event-id "evt_refund"
             #:kind 'payment-refunded)
      #:received-at 21)
     (define refund-result
       (storage-project-next! storage #:processed-at 22))
     (check-equal? (length (projection-result-outbox refund-result)) 1)
     (define withdrawal-result
       (process-issuance-work! (worker 300) storage))
     (check-eq? (issuance-result-disposition withdrawal-result) 'completed)
     (check-equal? (issuance-result-revision withdrawal-result) 1)
     (define revision
       (issuance-completion-revision
        (issuance-result-completion withdrawal-result)))
     (define successor
       (with-input-from-bytes
           (entitlement-revision-payload-bytes revision)
         read-json))
     ;; Cancellation at period end: the successor expires when the paid
     ;; window ends, not when the withdrawal was issued.
     (check-equal?
      (hash-ref (hash-ref successor 'constraints) 'use_expires_at)
      (rfc3339-for 1794694400))
     (storage-close storage)
     (check-equal? (count-revisions path) 2))))

(test-case "worker refuses a one-time second purchase over a lineage"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-sqlite-commerce-storage path))
     (define payload #"one-time purchase")
     (journal-accept!
      storage payload
      (make-verified-payment-event
       "mock" "evt_once" (payload-digest payload) 'payment-succeeded
       "ord_once" "taskly-pro-monthly" "customer-001"
       usd-999 1792108800)
      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define first (process-issuance-work! (worker 100) storage))
     (check-eq? (issuance-result-disposition first) 'completed)
     (define second-payload #"second one-time purchase")
     (journal-accept!
      storage second-payload
      (make-verified-payment-event
       "mock" "evt_once_2" (payload-digest second-payload)
       'payment-succeeded "ord_once_2" "taskly-pro-monthly" "customer-001"
       usd-999 1792108900)
      #:received-at 21)
     (storage-project-next! storage #:processed-at 22)
     (define second (process-issuance-work! (worker 200) storage))
     (check-eq? (issuance-result-disposition second) 'released)
     (check-eq? (issuance-result-error-code second)
                'entitlement-lineage-conflict)
     (storage-close storage)
     (check-equal? (count-revisions path) 1))))
