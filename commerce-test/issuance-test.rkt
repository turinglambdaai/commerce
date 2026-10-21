#lang racket/base

(require commerce
         commerce/journal
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         db
         file/sha1
         rackunit
         racket/file)

(define usd-29 (money "USD" 2900))

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

(define (event payload
               #:event-id [event-id "evt_001"]
               #:kind [kind 'payment-succeeded]
               #:order-id [order-id "ord_001"]
               #:offer [offer-id "taskly-pro-lifetime"]
               #:subject [subject-id "customer-001"]
               #:occurred-at [occurred-at 1792108800])
  (make-verified-payment-event
   "mock" event-id (payload-digest payload) kind order-id offer-id subject-id
   usd-29 occurred-at))

;; One unique directory per database so rapid calls never share a path;
;; deleting the directory removes sidecar files as well.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-issuance-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

;; Projects one paid mock order so its grant work sits in the outbox.
;; The surrounding test-case owns the temporary database path.
(define (call-with-paid-storage path proc
                                #:order-id [order-id "ord_001"]
                                #:subject [subject-id "customer-001"])
  (define payload #"authenticated payment")
  (define storage (open-sqlite-commerce-storage path))
  (journal-accept!
   storage payload
   (event payload #:order-id order-id #:subject subject-id)
   #:received-at 10)
  (storage-project-next! storage #:processed-at 11)
  (proc storage))

(define (database-count path table)
  (define connection (sqlite3-connect #:database path #:mode 'read-only))
  (begin0
    (query-value connection (format "SELECT COUNT(*) FROM ~a" table))
    (disconnect connection)))

;; Builds a completion call with defaulted deterministic ids; keyword
;; overrides keep individual tests focused on one varied input.
(define (grant-completion-arguments #:entitlement-id [entitlement-id "ent-001"]
                                    #:credential-id [credential-id "cred-001"]
                                    #:payload [payload #"grant-payload-bytes"]
                                    #:recorded-at [recorded-at 120])
  (lambda (storage item)
    (storage-complete-issuance-work! storage item
                                     #:issuer "commerce.example"
                                     #:subject-type "person"
                                     #:entitlement-id entitlement-id
                                     #:credential-id credential-id
                                     #:policy-id "taskly-pro-lifetime-v1"
                                     #:policy-version 1
                                     #:payload-bytes payload
                                     #:issued-at "2026-10-21T00:00:00Z"
                                     #:recorded-at recorded-at)))

(define (apply-completion storage item arguments)
  (arguments storage item))

(test-case "claim returns due work exactly once under an exclusive lease"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (check-false
         (storage-claim-issuance-work! storage
                                       #:owner "worker-a"
                                       #:lease-seconds 30
                                       #:now 5))
        (define claimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (check-equal? (issuance-outbox-item-idempotency-key claimed)
                      "mock/ord_001/grant")
        (check-eq? (issuance-outbox-item-status claimed) 'processing)
        (check-equal? (issuance-outbox-item-attempts claimed) 1)
        (check-false (issuance-outbox-item-last-error-code claimed))
        (check-equal? (issuance-outbox-item-lease-owner claimed) "worker-a")
        (check-equal? (issuance-outbox-item-lease-expires-at claimed) 130)
        (check-equal? (issuance-outbox-item-available-at claimed) 11)
        (check-false
         (storage-claim-issuance-work! storage
                                       #:owner "worker-b"
                                       #:lease-seconds 30
                                       #:now 110))
        (check-equal?
         (storage-outbox-ref storage "mock/ord_001/grant")
         claimed)
        (storage-close storage)
        (define connection
          (sqlite3-connect #:database path #:mode 'read-only))
        (check-equal?
         (query-row
          connection
          #<<SQL
SELECT status, attempts, lease_owner, lease_expires_at
FROM commerce_issuance_outbox
SQL
          )
         (vector "processing" 1 "worker-a" 130))
        (disconnect connection))))))

(test-case "an expired lease is reclaimable and attempts accumulate"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define first-claim
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (check-equal?
         (issuance-outbox-item-lease-owner first-claim) "worker-a")
        (check-false
         (storage-claim-issuance-work! storage
                                       #:owner "worker-b"
                                       #:lease-seconds 30
                                       #:now 129))
        (define reclaimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-b"
                                        #:lease-seconds 30
                                        #:now 130))
        (check-equal? (issuance-outbox-item-id reclaimed)
                      (issuance-outbox-item-id first-claim))
        (check-equal? (issuance-outbox-item-lease-owner reclaimed) "worker-b")
        (check-equal? (issuance-outbox-item-lease-expires-at reclaimed) 160)
        (check-equal? (issuance-outbox-item-attempts reclaimed) 2)
        (check-false
         (storage-claim-issuance-work! storage
                                       #:owner "worker-c"
                                       #:lease-seconds 30
                                       #:now 140))
        (storage-close storage))))))

(test-case "owner-checked completion appends the lineage root and revision zero"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define claimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (define completion
          (apply-completion storage claimed (grant-completion-arguments)))
        (define item (issuance-completion-outbox completion))
        (define revision (issuance-completion-revision completion))
        (check-eq? (issuance-outbox-item-status item) 'completed)
        (check-equal? (issuance-outbox-item-completed-at item) 120)
        (check-false (issuance-outbox-item-lease-owner item))
        (check-false (issuance-outbox-item-lease-expires-at item))
        (check-equal? (issuance-outbox-item-updated-at item) 120)
        (check-equal? (entitlement-revision-entitlement-id revision) "ent-001")
        (check-equal? (entitlement-revision-revision revision) 0)
        (check-false (entitlement-revision-previous-revision revision))
        (check-equal? (entitlement-revision-credential-id revision) "cred-001")
        (check-equal? (entitlement-revision-issuance-outbox-id revision)
                      (issuance-outbox-item-id claimed))
        (check-eq? (entitlement-revision-action revision) 'grant)
        (check-equal? (entitlement-revision-policy-id revision)
                      "taskly-pro-lifetime-v1")
        (check-equal? (entitlement-revision-policy-version revision) 1)
        (check-equal? (entitlement-revision-payload-bytes revision)
                      #"grant-payload-bytes")
        (check-equal? (entitlement-revision-payload-digest revision)
                      (payload-digest #"grant-payload-bytes"))
        (check-equal? (entitlement-revision-issued-at revision)
                      "2026-10-21T00:00:00Z")
        (check-equal? (entitlement-revision-recorded-at revision) 120)
        (storage-close storage)

        (define connection
          (sqlite3-connect #:database path #:mode 'read-only))
        (check-equal?
         (query-row
          connection
          #<<SQL
SELECT entitlement_id, issuer, subject_type, subject_id, credential_type,
       offer_id, created_at
FROM commerce_entitlement_lineage
SQL
          )
         (vector "ent-001" "commerce.example" "person" "customer-001"
                 "entitlement" "taskly-pro-lifetime" 120))
        (check-equal?
         (query-value
          connection
          "SELECT status FROM commerce_issuance_outbox WHERE id = 1")
         "completed")
        (check-equal?
         (query-value
          connection
          "SELECT COUNT(*) FROM commerce_entitlement_revision")
         1)
        (disconnect connection)

        (define reopened (open-sqlite-commerce-storage path))
        (check-false
         (storage-claim-issuance-work! reopened
                                       #:owner "worker-b"
                                       #:lease-seconds 30
                                       #:now 200))
        (storage-close reopened))))))

(test-case "completion without the active lease fails closed"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure) 'lease-not-held)))
         (lambda ()
           (apply-completion
            storage
            (storage-outbox-ref storage "mock/ord_001/grant")
            (grant-completion-arguments))))
        (define claimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure) 'lease-not-held)))
         (lambda ()
           (apply-completion
            storage claimed
            (grant-completion-arguments #:recorded-at 131))))
        (define completed
          (apply-completion
           storage claimed (grant-completion-arguments #:recorded-at 120)))
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure) 'lease-not-held)))
         (lambda ()
           (storage-release-issuance-work! storage
                                           (issuance-completion-outbox
                                            completed)
                                           #:error-code
                                           'issuer-unavailable
                                           #:retry-at 300)))
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure) 'unknown-issuance-work)))
         (lambda ()
           ;; Remove the row behind the claimed item to prove that completion
           ;; detects vanished work instead of writing orphan evidence.
           (define connection
             (sqlite3-connect #:database path #:mode 'read/write))
           (query-exec connection "DELETE FROM commerce_issuance_outbox")
           (disconnect connection)
           (apply-completion storage claimed (grant-completion-arguments))))
        (storage-close storage))))))

(test-case "repeated completion reconciles to the recorded revision"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define claimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (define first
          (apply-completion
           storage claimed (grant-completion-arguments)))
        (define second
          (apply-completion
           storage claimed (grant-completion-arguments)))
        (check-equal? second first)
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure)
                     'entitlement-lineage-conflict)))
         (lambda ()
           (apply-completion
            storage claimed
            (grant-completion-arguments
             #:payload #"different-payload-bytes"))))
        (storage-close storage)
        (check-equal? (database-count path "commerce_entitlement_revision") 1)
        (check-equal? (database-count path "commerce_entitlement_lineage") 1))))))

(test-case "release returns work to pending with the error recorded"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define claimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (define released
          (storage-release-issuance-work! storage claimed
                                          #:error-code 'issuer-unavailable
                                          #:retry-at 200))
        (check-eq? (issuance-outbox-item-status released) 'pending)
        (check-equal? (issuance-outbox-item-attempts released) 1)
        (check-equal? (issuance-outbox-item-available-at released) 200)
        (check-eq? (issuance-outbox-item-last-error-code released)
                   'issuer-unavailable)
        (check-false (issuance-outbox-item-lease-owner released))
        (check-false (issuance-outbox-item-lease-expires-at released))
        (check-false
         (storage-claim-issuance-work! storage
                                       #:owner "worker-b"
                                       #:lease-seconds 30
                                       #:now 199))
        (define retried
          (storage-claim-issuance-work! storage
                                        #:owner "worker-b"
                                        #:lease-seconds 30
                                        #:now 200))
        (check-equal? (issuance-outbox-item-attempts retried) 2)
        (check-eq? (issuance-outbox-item-last-error-code retried)
                   'issuer-unavailable)
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure) 'lease-not-held)))
         (lambda ()
           (storage-release-issuance-work! storage claimed
                                           #:error-code 'issuer-unavailable
                                           #:retry-at 300)))
        (storage-close storage))))))

(test-case "one commercial identity cannot silently acquire a second lineage"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define first-claim
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (apply-completion
         storage first-claim (grant-completion-arguments))
        (define second-payload #"second payment")
        (journal-accept!
         storage second-payload
         (event second-payload #:event-id "evt_002" #:order-id "ord_002")
         #:received-at 20)
        (storage-project-next! storage #:processed-at 21)
        (define second-claim
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 200))
        (check-equal? (issuance-outbox-item-idempotency-key second-claim)
                      "mock/ord_002/grant")
        (for ([entitlement-id (list "ent-001" "ent-002")])
          (check-exn
           (lambda (failure)
             (and (exn:fail:commerce? failure)
                  (eq? (exn:fail:commerce-code failure)
                       'entitlement-lineage-conflict)))
           (lambda ()
             (apply-completion
              storage second-claim
              (grant-completion-arguments
               #:entitlement-id entitlement-id
               #:credential-id "cred-002"
               #:recorded-at 210)))))
        (storage-close storage)
        (check-equal? (database-count path "commerce_entitlement_lineage") 1)
        (check-equal? (database-count path "commerce_entitlement_revision") 1)
        (define connection
          (sqlite3-connect #:database path #:mode 'read-only))
        (check-equal?
         (query-value
          connection
          "SELECT status FROM commerce_issuance_outbox WHERE id = 2")
         "processing")
        (disconnect connection))))))

(test-case "a withdrawal appends exactly one successor revision"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define grant-claim
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (apply-completion storage grant-claim (grant-completion-arguments))
        (define refund-payload #"authenticated refund")
        (journal-accept!
         storage refund-payload
         (event refund-payload #:event-id "evt_refund"
                #:kind 'payment-refunded #:occurred-at 20)
         #:received-at 21)
        (storage-project-next! storage #:processed-at 22)
        (define withdraw-claim
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 200))
        (check-equal? (issuance-outbox-item-idempotency-key withdraw-claim)
                      "mock/ord_001/withdraw")
        (define previous
          (storage-latest-entitlement-revision storage "ent-001"))
        (check-equal? (entitlement-revision-revision previous) 0)
        (define successor-payload
          (bytes-append #"successor-of:"
                        (entitlement-revision-payload-bytes previous)))
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure)
                     'entitlement-lineage-conflict)))
         (lambda ()
           (apply-completion
            storage withdraw-claim
            (grant-completion-arguments
             #:entitlement-id "ent-other"
             #:credential-id "cred-002"
             #:payload successor-payload
             #:recorded-at 210))))
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure)
                     'entitlement-lineage-conflict)))
         (lambda ()
           (apply-completion
            storage withdraw-claim
            (grant-completion-arguments
             #:credential-id "cred-001"
             #:payload successor-payload
             #:recorded-at 210))))
        (define completion
          (apply-completion
           storage withdraw-claim
           (grant-completion-arguments
            #:credential-id "cred-002"
            #:payload successor-payload
            #:recorded-at 210)))
        (define revision (issuance-completion-revision completion))
        (check-equal? (entitlement-revision-entitlement-id revision) "ent-001")
        (check-equal? (entitlement-revision-revision revision) 1)
        (check-equal? (entitlement-revision-previous-revision revision) 0)
        (check-eq? (entitlement-revision-action revision) 'withdraw)
        (storage-close storage)
        (check-equal? (database-count path "commerce_entitlement_revision") 2))))))

(test-case "withdrawal without lineage is deterministic operator work"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define grant-claim
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (storage-release-issuance-work! storage grant-claim
                                        #:error-code 'issuer-unavailable
                                        #:retry-at 100000)
        (define refund-payload #"authenticated refund")
        (journal-accept!
         storage refund-payload
         (event refund-payload #:event-id "evt_refund"
                #:kind 'payment-refunded #:occurred-at 20)
         #:received-at 21)
        (storage-project-next! storage #:processed-at 22)
        (define withdraw-claim
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 200))
        (check-equal? (issuance-outbox-item-idempotency-key withdraw-claim)
                      "mock/ord_001/withdraw")
        (check-exn
         (lambda (failure)
           (and (exn:fail:commerce? failure)
                (eq? (exn:fail:commerce-code failure)
                     'entitlement-lineage-required)))
         (lambda ()
           (apply-completion
            storage withdraw-claim
            (grant-completion-arguments #:credential-id "cred-001"
                                        #:recorded-at 210))))
        (storage-close storage)
        (check-equal? (database-count path "commerce_entitlement_lineage") 0)
        (check-equal? (database-count path "commerce_entitlement_revision") 0))))))

(test-case "completion failure rolls lineage and outbox back as one unit"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (define claimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (storage-close storage)
        (define connection
          (sqlite3-connect #:database path #:mode 'read/write))
        (query-exec
         connection
         #<<SQL
CREATE TRIGGER fail_revision_insert
BEFORE INSERT ON commerce_entitlement_revision
BEGIN
  SELECT RAISE(ABORT, 'injected revision failure');
END
SQL
         )
        (disconnect connection)
        (define failing (open-sqlite-commerce-storage path))
        (check-exn
         exn:fail:sql?
         (lambda ()
           (apply-completion
            failing claimed (grant-completion-arguments))))
        (storage-close failing)
        (check-equal? (database-count path "commerce_entitlement_lineage") 0)
        (check-equal? (database-count path "commerce_entitlement_revision") 0)
        (define repair
          (sqlite3-connect #:database path #:mode 'read/write))
        (query-exec repair "DROP TRIGGER fail_revision_insert")
        (disconnect repair)
        (define retried (open-sqlite-commerce-storage path))
        (define completion
          (apply-completion
           retried claimed (grant-completion-arguments)))
        (check-eq? (issuance-outbox-item-status
                    (issuance-completion-outbox completion))
                   'completed)
        (storage-close retried)))))

(test-case "lineage and revision readers expose durable audit state"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (check-false (storage-entitlement-ref storage "ent-001"))
        (check-false
         (storage-lineage-ref storage
                              #:issuer "commerce.example"
                              #:subject-type "person"
                              #:subject-id "customer-001"
                              #:offer-id "taskly-pro-lifetime"))
        (check-false
         (storage-latest-entitlement-revision storage "ent-001"))
        (define claimed
          (storage-claim-issuance-work! storage
                                        #:owner "worker-a"
                                        #:lease-seconds 30
                                        #:now 100))
        (apply-completion storage claimed (grant-completion-arguments))
        (define lineage (storage-entitlement-ref storage "ent-001"))
        (check-equal? (entitlement-lineage-entitlement-id lineage) "ent-001")
        (check-equal? (entitlement-lineage-issuer lineage)
                      "commerce.example")
        (check-equal? (entitlement-lineage-subject-type lineage) "person")
        (check-equal? (entitlement-lineage-subject-id lineage)
                      "customer-001")
        (check-equal? (entitlement-lineage-offer-id lineage)
                      "taskly-pro-lifetime")
        (check-equal? (entitlement-lineage-created-at lineage) 120)
        (check-equal?
         (storage-lineage-ref storage
                              #:issuer "commerce.example"
                              #:subject-type "person"
                              #:subject-id "customer-001"
                              #:offer-id "taskly-pro-lifetime")
         lineage)
        (check-false
         (storage-lineage-ref storage
                              #:issuer "commerce.example"
                              #:subject-type "person"
                              #:subject-id "customer-001"
                              #:offer-id "taskly-pro-team"))
        (define revision
          (storage-entitlement-revision-ref storage "ent-001" 0))
        (check-equal?
         revision
         (storage-latest-entitlement-revision storage "ent-001"))
        (check-false
         (storage-entitlement-revision-ref storage "ent-001" 1))
        (storage-close storage))))))

(test-case "lease and writer arguments are validated before any mutation"
  (call-with-temporary-database
   (lambda (path)
     (call-with-paid-storage path
      (lambda (storage)
        (check-exn
         exn:fail:contract?
         (lambda ()
           (storage-claim-issuance-work! storage
                                         #:owner "worker-a"
                                         #:lease-seconds 30
                                         #:now "not-a-time")))
        (check-exn
         exn:fail:contract?
         (lambda ()
           (storage-claim-issuance-work! storage
                                         #:owner ""
                                         #:lease-seconds 30
                                         #:now 100)))
        (check-exn
         exn:fail:contract?
         (lambda ()
           (storage-claim-issuance-work! storage
                                         #:owner "worker-a"
                                         #:lease-seconds 0
                                         #:now 100)))
        (storage-close storage)))))))
