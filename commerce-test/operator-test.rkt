#lang racket/base

(require commerce
         commerce/issuer
         commerce/journal
         commerce/operator
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         db
         file/sha1
         permit/issuer
         rackunit
         racket/file
         racket/port)

(define usd-29 (money "USD" 2900))

(define taskly-offer
  (offer "taskly-pro-lifetime" "taskly" 'one-time usd-29 "taskly-pro-v1"))

(define taskly-policy
  (make-permit-entitlement-policy
   "taskly-pro-v1" 1
   #:subject-type 'person
   #:grants (list (make-permit-grant-policy #:products '("taskly")))))

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

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

;; One unique directory per database so rapid calls never share a path.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-operator-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (event payload
               #:event-id [event-id "evt_001"]
               #:kind [kind 'payment-succeeded]
               #:order-id [order-id "ord_001"]
               #:occurred-at [occurred-at 1792108800])
  (make-verified-payment-event
   "mock" event-id (payload-digest payload) kind order-id
   "taskly-pro-lifetime" "customer-001" usd-29 occurred-at))

(define (worker clock-epoch)
  (make-issuance-worker
   #:catalog catalog
   #:issuer issuer-name
   #:private-key private-key
   #:key-id key-id
   #:trust-store trust-store
   #:clock (lambda () (values clock-epoch "2026-10-21T00:00:00Z"))))

(define (failure-code expected thunk)
  (check-exn
   (lambda (failure)
     (and (exn:fail:commerce? failure)
          (eq? (exn:fail:commerce-code failure) expected)))
   thunk))

(test-case "find and explain surface the full paid-refund story"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload (event payload) #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define refund-payload #"authenticated refund")
     (journal-accept!
      storage refund-payload
      (event refund-payload #:event-id "evt_refund"
             #:kind 'payment-refunded #:occurred-at 20)
      #:received-at 21)
     (storage-project-next! storage #:processed-at 22)
     (define grant-work
       (storage-outbox-ref storage "mock/ord_001/grant"))
     ;; One worker pass completes the grant (with its credential and claim);
     ;; the refund's withdrawal is still pending, which is exactly the
     ;; mid-flight state an operator inspects.
     (define issuance-worker (worker 120))
     (process-issuance-work! issuance-worker storage)

     (define pending (find-issuance-work storage #:status 'pending))
     (check-equal? (length pending) 1)
     (check-equal? (issuance-outbox-item-idempotency-key (car pending))
                   "mock/ord_001/withdraw")
     (define completed (find-issuance-work storage #:status 'completed))
     (check-equal? (length completed) 1)
     (check-equal? (issuance-outbox-item-idempotency-key (car completed))
                   "mock/ord_001/grant")

     (define explanation (explain-order storage "mock" "ord_001"))
     (define order (order-explanation-order explanation))
     (check-true (order-projection-paid? order))
     (check-true (order-projection-refunded? order))
     (define events (order-explanation-events explanation))
     (check-equal? (length events) 2)
     (check-true (andmap payment-event? events))
     (check-eq? (payment-event-kind (car events)) 'payment-succeeded)
     (check-eq? (payment-event-kind (cadr events)) 'payment-refunded)
     (define work (order-explanation-work explanation))
     (check-equal? (length work) 2)
     (define credentials
       (order-explanation-credentials explanation))
     (check-equal? (length credentials) 2)
     (check-true (issued-credential-record? (car credentials)))
     (check-false (cadr credentials))
     (check-equal?
      (issued-credential-record-entitlement-id (car credentials))
      (issued-credential-record-entitlement-id
       (storage-issued-credential-ref
        storage
        (issuance-outbox-item-id grant-work))))
     (storage-close storage))))

(test-case "redrive makes pending work due and never rewinds finished work"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload (event payload) #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define work (storage-outbox-ref storage "mock/ord_001/grant"))
     (check-equal? (issuance-outbox-item-attempts work) 0)
     (define redriven
       (redrive-issuance-work! storage "mock/ord_001/grant" #:now 500))
     (check-equal? (issuance-outbox-item-available-at redriven) 500)
     (check-equal? (issuance-outbox-item-attempts redriven) 0)
     (define claimed
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 510))
     (check-equal? (issuance-outbox-item-attempts claimed) 1)
     (failure-code
      'lease-not-held
      (lambda ()
        (redrive-issuance-work! storage "mock/ord_001/grant" #:now 520)))
     (define completed
       (storage-complete-issuance-work!
        storage claimed
        #:issuer issuer-name
        #:subject-type "person"
        #:entitlement-id "ent-001"
        #:credential-id "cred-001"
        #:policy-id "taskly-pro-v1"
        #:policy-version 1
        #:payload-bytes (make-bytes 64 1)
        #:issued-at "2026-10-21T00:00:00Z"
        #:recorded-at 530))
     (check-eq? (issuance-outbox-item-status
                 (issuance-completion-outbox completed))
                'completed)
     (failure-code
      'work-already-completed
      (lambda ()
        (redrive-issuance-work! storage "mock/ord_001/grant" #:now 540)))
     (failure-code
      'unknown-issuance-work
      (lambda ()
        (redrive-issuance-work! storage "mock/missing/grant" #:now 540)))
     ;; Journal replay still reuses the immutable entry: an exact retry
     ;; acknowledges without a second projection or outbox row.
     (define replay
       (journal-accept! storage payload (event payload) #:received-at 600))
     (check-eq? (journal-acceptance-disposition replay) 'replayed)
     (check-false (storage-project-next! storage #:processed-at 610))
     (check-equal? (length (find-issuance-work storage)) 1)
     (storage-close storage))))
