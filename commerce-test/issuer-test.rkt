#lang racket/base

(require commerce
         commerce/issuer
         commerce/permit
         commerce/storage
         commerce/storage/sqlite
         commerce/journal
         commerce/provider
         db
         file/sha1
         json
         permit/envelope
         permit/issuer
         rackunit
         racket/file
         racket/port)

(define usd-29 (money "USD" 2900))

(define taskly-offer
  (offer "taskly-pro-lifetime" "taskly" 'one-time usd-29 "taskly-pro-v1"))

(define taskly-policy
  (make-permit-entitlement-policy
   "taskly-pro-v1"
   1
   #:subject-type 'person
   #:grants
   (list
    (make-permit-grant-policy
     #:products '("taskly")
     #:edition "pro"
     #:feature-policy 'published-through))
   #:constraints
   (make-permit-constraints-policy
    #:updates-through "2027-12-31T23:59:59Z")))

(define catalog
  (make-permit-policy-catalog (list taskly-offer) (list taskly-policy)))

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

;; The wrong key produces a typed Permit signing failure that the worker
;; must treat as transient.
(define-values (wrong-private-key _wrong-public-key)
  (generate-ed25519-keypair))

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

(define (payment-event* payload
                        #:event-id [event-id "evt_001"]
                        #:kind [kind 'payment-succeeded]
                        #:order-id [order-id "ord_001"]
                        #:occurred-at [occurred-at 1792108800])
  (make-verified-payment-event
   "mock" event-id (payload-digest payload) kind order-id
   "taskly-pro-lifetime" "customer-001" usd-29 occurred-at))

;; One unique directory per database so nested or rapid calls never share a
;; path; deleting the directory removes sidecar files as well.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-issuer-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

;; Opens storage, journals one paid mock event, and projects it so the grant
;; work is pending in the issuance outbox.
(define (open-paid-storage path)
  (define payload #"authenticated payment")
  (define storage (open-sqlite-commerce-storage path))
  (journal-accept! storage payload (payment-event* payload) #:received-at 10)
  (storage-project-next! storage #:processed-at 11)
  storage)

(define (clock-at epoch-seconds)
  (lambda () (values epoch-seconds (rfc3339-for epoch-seconds))))

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

(define (worker #:private-key [signing-key private-key]
                #:clock [clock (clock-at 100)])
  (make-issuance-worker
   #:catalog catalog
   #:issuer issuer-name
   #:private-key signing-key
   #:key-id key-id
   #:trust-store trust-store
   #:clock clock))

(define (database-count path table)
  (define connection (sqlite3-connect #:database path #:mode 'read-only))
  (begin0
    (query-value connection (format "SELECT COUNT(*) FROM ~a" table))
    (disconnect connection)))

(test-case "signing worker is opaque to diagnostics and log formatting"
  (define signing-worker (worker))
  (check-true (issuance-worker? signing-worker))
  (check-equal? (format "~s" signing-worker) "#<issuance-worker>")
  (check-equal? (format "~v" signing-worker) "#<issuance-worker>"))

(test-case "the worker signs a grant and records revision zero transactionally"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define result
       (process-issuance-work! (worker) storage))
     (check-eq? (issuance-result-disposition result) 'completed)
     ;; The result carries a one-time claim token, never safe to log via ~s.
     (check-equal? (format "~s" result) "#<issuance-result>")
     (check-equal? (format "~v" result) "#<issuance-result>")
     (check-false (issuance-result-error-code result))
     (check-equal? (issuance-result-revision result) 0)
     (define completion (issuance-result-completion result))
     (define revision (issuance-completion-revision completion))
     (check-equal? (issuance-result-entitlement-id result)
                   (entitlement-revision-entitlement-id revision))
     (check-equal? (entitlement-revision-revision revision) 0)
     (check-eq? (entitlement-revision-action revision) 'grant)
     (check-equal? (entitlement-revision-policy-id revision) "taskly-pro-v1")
     (check-equal? (entitlement-revision-policy-version revision) 1)
     (check-equal? (entitlement-revision-issued-at revision)
                   (rfc3339-for 100))
     (check-equal?
      (entitlement-revision-payload-digest revision)
      (payload-digest (entitlement-revision-payload-bytes revision)))
     ;; The recorded unsigned bytes are exactly what the configured key
     ;; signs, so the credential is reproducible from durable evidence.
     (define envelope
       (issue-credential (entitlement-revision-payload-bytes revision)
                         private-key key-id trust-store))
     (check-true (issued-credential? envelope))
     (check-equal? (permit-envelope-payload envelope)
                   (entitlement-revision-payload-bytes revision))
     (define item (issuance-completion-outbox completion))
     (check-eq? (issuance-outbox-item-status item) 'completed)
     (check-equal? (issuance-outbox-item-completed-at item) 100)
     (check-false (process-issuance-work! (worker) storage))
     (storage-close storage)
     (check-equal? (database-count path "commerce_entitlement_lineage") 1)
     (check-equal? (database-count path "commerce_entitlement_revision") 1))))

(test-case "entitlement and credential ids are deterministic across databases"
  (call-with-temporary-database
   (lambda (first-path)
     (call-with-temporary-database
      (lambda (second-path)
        (define first-storage (open-paid-storage first-path))
        (define second-storage (open-paid-storage second-path))
        (define first-result
          (process-issuance-work! (worker) first-storage))
        (define second-result
          (process-issuance-work! (worker) second-storage))
        (check-equal?
         (issuance-result-entitlement-id first-result)
         (issuance-result-entitlement-id second-result))
        (check-equal?
         (derive-entitlement-id issuer-name "person" "customer-001"
                                "taskly-pro-lifetime")
         (issuance-result-entitlement-id first-result))
        (check-not-equal?
         (derive-entitlement-id issuer-name "person" "customer-002"
                                "taskly-pro-lifetime")
         (issuance-result-entitlement-id first-result))
        (check-equal?
         (derive-credential-id (issuance-result-entitlement-id first-result)
                               0)
         (entitlement-revision-credential-id
          (issuance-completion-revision
           (issuance-result-completion first-result))))
        (storage-close first-storage)
        (storage-close second-storage))))))

(test-case "a withdrawal signs an issuance-expiring successor revision"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define grant-result (process-issuance-work! (worker) storage))
     (check-eq? (issuance-result-disposition grant-result) 'completed)
     (define refund-payload #"authenticated refund")
     (journal-accept!
      storage refund-payload
      (payment-event* refund-payload #:event-id "evt_refund"
                      #:kind 'payment-refunded #:occurred-at 20)
      #:received-at 21)
     (storage-project-next! storage #:processed-at 22)
     (define withdraw-result
       (process-issuance-work! (worker #:clock (clock-at 200)) storage))
     (check-eq? (issuance-result-disposition withdraw-result) 'completed)
     (check-equal? (issuance-result-revision withdraw-result) 1)
     (define revision
       (issuance-completion-revision
        (issuance-result-completion withdraw-result)))
     (check-equal? (entitlement-revision-previous-revision revision) 0)
     (check-eq? (entitlement-revision-action revision) 'withdraw)
     (define successor
       (with-input-from-bytes
           (entitlement-revision-payload-bytes revision)
         read-json))
     (check-equal? (hash-ref successor 'revision) 1)
     (check-equal? (hash-ref successor 'issued_at) (rfc3339-for 200))
     (check-equal?
      (hash-ref (hash-ref successor 'constraints) 'use_expires_at)
      (rfc3339-for 200))
     (check-equal?
      (hash-ref successor 'credential_id)
      (derive-credential-id (issuance-result-entitlement-id withdraw-result)
                            1))
     (storage-close storage)
     (check-equal? (database-count path "commerce_entitlement_revision") 2))))

(test-case "a deleted Offer fails before signing with a typed release"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"payment for a deleted offer")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept!
      storage payload
      (make-verified-payment-event
       "mock" "evt_del" (payload-digest payload) 'payment-succeeded
       "ord_del" "taskly-pro-lifetime" "customer-001" usd-29 1792108800)
      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define deleted-catalog
       (make-permit-policy-catalog
        (list)
        (list taskly-policy)
        #:deleted-offer-ids '("taskly-pro-lifetime")))
     (define deleting-worker
       (make-issuance-worker
        #:catalog deleted-catalog
        #:issuer issuer-name
        #:private-key private-key
        #:key-id key-id
        #:trust-store trust-store
        #:clock (clock-at 100)
        #:operator-backoff-seconds 500))
     (define result (process-issuance-work! deleting-worker storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-eq? (issuance-result-error-code result) 'offer-deleted)
     (check-false (issuance-result-completion result))
     (define work
       (storage-outbox-ref storage "mock/ord_del/grant"))
     (check-eq? (issuance-outbox-item-status work) 'pending)
     (check-equal? (issuance-outbox-item-attempts work) 1)
     (check-equal? (issuance-outbox-item-available-at work) 600)
     (check-eq? (issuance-outbox-item-last-error-code work) 'offer-deleted)
     (storage-close storage)
     (check-equal? (database-count path "commerce_entitlement_revision") 0))))

(test-case "a signing key mismatch releases transient work with backoff"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define mismatched
       (worker #:private-key wrong-private-key))
     (define result (process-issuance-work! mismatched storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-eq? (issuance-result-error-code result) 'permit-issue-failed)
     (define work (storage-outbox-ref storage "mock/ord_001/grant"))
     (check-eq? (issuance-outbox-item-status work) 'pending)
     (check-equal? (issuance-outbox-item-attempts work) 1)
     (check-equal? (issuance-outbox-item-available-at work) 130)
     (check-eq? (issuance-outbox-item-last-error-code work)
                'permit-issue-failed)
     ;; Repair the trust configuration: the same durable work completes.
     (define repaired (worker #:clock (clock-at 200)))
     (define retried (process-issuance-work! repaired storage))
     (check-eq? (issuance-result-disposition retried) 'completed)
     (check-equal? (issuance-outbox-item-attempts
                    (storage-outbox-ref storage "mock/ord_001/grant"))
                   2)
     (storage-close storage)
     (check-equal? (database-count path "commerce_entitlement_revision") 1))))

(test-case "an expired lease between claim and completion reports lease-lost"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     ;; The clock returns 100 for the claim and 200 for completion, so the
     ;; 30-second lease has expired by completion time.
     (define ticks (box 0))
     (define expiring-clock
       (lambda ()
         (define tick (add1 (unbox ticks)))
         (set-box! ticks tick)
         (values (if (= tick 1) 100 200)
                 (rfc3339-for (if (= tick 1) 100 200)))))
     (define result
       (process-issuance-work!
        (worker #:clock expiring-clock)
        storage))
     (check-eq? (issuance-result-disposition result) 'lease-lost)
     (check-false (issuance-result-completion result))
     (define work (storage-outbox-ref storage "mock/ord_001/grant"))
     (check-eq? (issuance-outbox-item-status work) 'processing)
     (storage-close storage)
     (check-equal? (database-count path "commerce_entitlement_revision") 0))))

(test-case "Ed25519 signing is deterministic for identical recorded bytes"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define result (process-issuance-work! (worker) storage))
     (define bytes
       (entitlement-revision-payload-bytes
        (issuance-completion-revision
         (issuance-result-completion result))))
     (check-equal?
      (permit-envelope-signature
       (issue-credential bytes private-key key-id trust-store))
      (permit-envelope-signature
       (issue-credential bytes private-key key-id trust-store)))
     (storage-close storage))))
