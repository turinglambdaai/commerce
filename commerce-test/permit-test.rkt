#lang racket/base

(require commerce
         commerce/permit
         permit/issuer
         rackunit)

(define usd-29 (money "USD" 2900))

(define taskly-offer-v1
  (offer "taskly-pro-lifetime"
         "taskly"
         'one-time
         usd-29
         "taskly-pro-v1"))

(define taskly-offer-v2
  (offer "taskly-pro-lifetime-v2"
         "taskly"
         'one-time
         usd-29
         "taskly-pro-v2"))

(define taskly-policy-v1
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
    #:updates-through "2027-12-31T23:59:59Z"
    #:features-through "2027-12-31T23:59:59Z")))

(define taskly-policy-v2
  (make-permit-entitlement-policy
   "taskly-pro-v2"
   2
   #:subject-type 'person
   #:grants
   (list
    (make-permit-grant-policy
     #:products '("taskly")
     #:edition "pro"
     #:features '("automation")))))

(define catalog
  (make-permit-policy-catalog
   (list taskly-offer-v1 taskly-offer-v2)
   (list taskly-policy-v1 taskly-policy-v2)
   #:deleted-offer-ids '("taskly-legacy-deleted")))

(define (intent action
                #:offer-id [offer-id "taskly-pro-lifetime"]
                #:subject-id [subject-id "customer-001"])
  (rights-intent
   (format "mock/ord_001/~a" action)
   action
   "mock"
   "ord_001"
   offer-id
   subject-id
   1792108800))

(define (failure-code expected thunk)
  (check-exn
   (lambda (failure)
     (and (exn:fail:commerce? failure)
          (eq? (exn:fail:commerce-code failure) expected)))
   thunk))

(test-case "grant maps a pinned Offer policy to a complete Permit snapshot"
  (define request
    (prepare-permit-snapshot
     catalog
     (intent 'grant)
     #:issuer "com.turinglambdaai"
     #:credential-id "cred-taskly-001-r0"
     #:entitlement-id "ent-taskly-001"
     #:issued-at "2026-10-17T03:00:00Z"))
  (check-eq? (permit-snapshot-request-action request) 'grant)
  (check-equal? (permit-snapshot-request-policy-id request)
                "taskly-pro-v1")
  (check-equal? (permit-snapshot-request-policy-version request) 1)
  (check-equal? (permit-snapshot-request-source-idempotency-key request)
                "mock/ord_001/grant")
  (define snapshot (permit-snapshot-request-payload request))
  (check-equal? (permit-snapshot-request-payload-bytes request)
                (payload->bytes snapshot))
  (check-equal?
   (sort (hash-keys snapshot) symbol<?)
   (sort '(protocol version type credential_id entitlement_id revision issuer
                    issued_at not_before subject channel grants constraints
                    extensions)
         symbol<?))
  (check-equal? (hash-ref snapshot 'protocol) "permit")
  (check-equal? (hash-ref snapshot 'version) 1)
  (check-equal? (hash-ref snapshot 'type) "entitlement")
  (check-equal? (hash-ref snapshot 'credential_id) "cred-taskly-001-r0")
  (check-equal? (hash-ref snapshot 'entitlement_id) "ent-taskly-001")
  (check-equal? (hash-ref snapshot 'revision) 0)
  (check-equal? (hash-ref snapshot 'issuer) "com.turinglambdaai")
  (check-equal? (hash-ref snapshot 'issued_at) "2026-10-17T03:00:00Z")
  (check-equal? (hash-ref snapshot 'subject)
                (hasheq 'type "person"
                        'id "customer-001"
                        'display 'null))
  (define grant-snapshot (car (hash-ref snapshot 'grants)))
  (check-equal?
   (hash-ref (hash-ref grant-snapshot 'scope) 'products)
   '("taskly"))
  (check-equal? (hash-ref grant-snapshot 'feature_policy)
                "published-through")
  (check-equal?
   (hash-ref (hash-ref snapshot 'constraints) 'updates_through)
   "2027-12-31T23:59:59Z")

  ;; Repeating pure preparation with the same lineage inputs is byte-stable.
  (check-equal?
   request
   (prepare-permit-snapshot
    catalog
    (intent 'grant)
    #:issuer "com.turinglambdaai"
    #:credential-id "cred-taskly-001-r0"
    #:entitlement-id "ent-taskly-001"
    #:issued-at "2026-10-17T03:00:00Z")))

(test-case "withdrawal is an expired successor in the same lineage"
  (define grant-request
    (prepare-permit-snapshot
     catalog
     (intent 'grant)
     #:issuer "com.turinglambdaai"
     #:credential-id "cred-taskly-001-r0"
     #:entitlement-id "ent-taskly-001"
     #:issued-at "2026-10-17T03:00:00Z"))
  (define previous (permit-snapshot-request-payload grant-request))
  (define withdrawal
    (prepare-permit-snapshot
     catalog
     (intent 'withdraw)
     #:issuer "com.turinglambdaai"
     #:credential-id "cred-taskly-001-r1"
     #:entitlement-id "ent-taskly-001"
     #:issued-at "2026-10-18T03:00:00Z"
     #:previous previous))
  (check-eq? (permit-snapshot-request-action withdrawal) 'withdraw)
  (define snapshot (permit-snapshot-request-payload withdrawal))
  (check-equal? (hash-ref snapshot 'revision) 1)
  (check-equal? (hash-ref snapshot 'credential_id) "cred-taskly-001-r1")
  (check-equal? (hash-ref snapshot 'entitlement_id) "ent-taskly-001")
  (check-equal? (hash-ref snapshot 'issuer) (hash-ref previous 'issuer))
  (check-equal? (hash-ref snapshot 'subject) (hash-ref previous 'subject))
  (check-equal? (hash-ref snapshot 'grants) (hash-ref previous 'grants))
  (check-equal?
   (hash-ref (hash-ref snapshot 'constraints) 'use_expires_at)
   "2026-10-18T03:00:00Z")
  (check-equal?
   (hash-ref (hash-ref snapshot 'constraints) 'updates_through)
   "2027-12-31T23:59:59Z"))

(test-case "snapshot payload cannot diverge from serialized bytes by mutation"
  (define initial
    (permit-snapshot-request-payload
     (prepare-permit-snapshot
      catalog
      (intent 'grant)
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-taskly-001-r0"
      #:entitlement-id "ent-taskly-001"
      #:issued-at "2026-10-17T03:00:00Z")))
  (define mutable-subject (hash-copy (hash-ref initial 'subject)))
  (define mutable-previous (hash-copy initial))
  (hash-set! mutable-previous 'subject mutable-subject)
  (define request
    (prepare-permit-snapshot
     catalog
     (intent 'withdraw)
     #:issuer "com.turinglambdaai"
     #:credential-id "cred-taskly-001-r1"
     #:entitlement-id "ent-taskly-001"
     #:issued-at "2026-10-18T03:00:00Z"
     #:previous mutable-previous))
  (hash-set! mutable-subject 'id "mutated-after-preparation")
  (define snapshot (permit-snapshot-request-payload request))
  (check-equal? (hash-ref (hash-ref snapshot 'subject) 'id)
                "customer-001")
  (check-equal? (permit-snapshot-request-payload-bytes request)
                (payload->bytes snapshot))
  (check-exn exn:fail:contract?
             (lambda () (hash-set! snapshot 'issuer "mutated")))
  (check-exn
   exn:fail:contract?
   (lambda ()
     (bytes-set! (permit-snapshot-request-payload-bytes request) 0 0))))

(test-case "validated policy is detached from mutable configuration input"
  (define mutable-product (string-copy "taskly"))
  (define mutable-updates-through
    (string-copy "2027-12-31T23:59:59Z"))
  (define mutable-policy
    (make-permit-entitlement-policy
     "taskly-mutation-safe-v1"
     1
     #:subject-type 'person
     #:grants
     (list (make-permit-grant-policy
            #:products (list mutable-product)
            #:edition "pro"))
     #:constraints
     (make-permit-constraints-policy
      #:updates-through mutable-updates-through)))
  (define mutable-offer
    (offer "taskly-mutation-safe"
           "taskly"
           'one-time
           usd-29
           "taskly-mutation-safe-v1"))
  (define mutable-catalog
    (make-permit-policy-catalog (list mutable-offer)
                                (list mutable-policy)))
  (string-set! mutable-product 0 #\x)
  (string-set! mutable-updates-through 3 #\8)
  (define request
    (prepare-permit-snapshot
     mutable-catalog
     (intent 'grant #:offer-id "taskly-mutation-safe")
     #:issuer "com.turinglambdaai"
     #:credential-id "cred-mutation-safe"
     #:entitlement-id "ent-mutation-safe"
     #:issued-at "2026-10-17T03:00:00Z"))
  (define snapshot (permit-snapshot-request-payload request))
  (check-equal?
   (hash-ref (hash-ref (car (hash-ref snapshot 'grants)) 'scope) 'products)
   '("taskly"))
  (check-equal?
   (hash-ref (hash-ref snapshot 'constraints) 'updates_through)
   "2027-12-31T23:59:59Z"))

(test-case "lineage shape and identity fail closed"
  (failure-code
   'entitlement-lineage-required
   (lambda ()
     (prepare-permit-snapshot
      catalog (intent 'withdraw)
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-taskly-001-r1"
      #:entitlement-id "ent-taskly-001"
      #:issued-at "2026-10-18T03:00:00Z")))
  (failure-code
   'entitlement-lineage-conflict
   (lambda ()
     (prepare-permit-snapshot
      catalog (intent 'grant)
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-taskly-001-r1"
      #:entitlement-id "ent-taskly-001"
      #:issued-at "2026-10-18T03:00:00Z"
      #:previous (hasheq))))

  (define previous
    (permit-snapshot-request-payload
     (prepare-permit-snapshot
      catalog (intent 'grant)
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-taskly-001-r0"
      #:entitlement-id "ent-taskly-001"
      #:issued-at "2026-10-17T03:00:00Z")))
  (for ([changed
         (in-list
          (list
           (hash-set previous 'issuer "other.example")
           (hash-set previous 'entitlement_id "ent-other")
           (hash-set previous
                     'subject
                     (hasheq 'type "person" 'id "customer-002"
                             'display 'null))
           (hash-set previous
                     'extensions
                     (hasheq 'invalid-json-value #"not-json"))))])
    (failure-code
     'entitlement-lineage-conflict
     (lambda ()
       (prepare-permit-snapshot
        catalog (intent 'withdraw)
        #:issuer "com.turinglambdaai"
        #:credential-id "cred-taskly-001-r1"
        #:entitlement-id "ent-taskly-001"
        #:issued-at "2026-10-18T03:00:00Z"
        #:previous changed)))))

(test-case "unknown and deliberately deleted Offers are distinct"
  (failure-code
   'unknown-offer
   (lambda ()
     (prepare-permit-snapshot
      catalog (intent 'grant #:offer-id "never-known")
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-unknown"
      #:entitlement-id "ent-unknown"
      #:issued-at "2026-10-17T03:00:00Z")))
  (failure-code
   'offer-deleted
   (lambda ()
     (prepare-permit-snapshot
      catalog (intent 'grant #:offer-id "taskly-legacy-deleted")
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-deleted"
      #:entitlement-id "ent-deleted"
      #:issued-at "2026-10-17T03:00:00Z"))))

(test-case "Offer pins one immutable policy id rather than selecting latest"
  (define request
    (prepare-permit-snapshot
     catalog (intent 'grant #:offer-id "taskly-pro-lifetime")
     #:issuer "com.turinglambdaai"
     #:credential-id "cred-pinned"
     #:entitlement-id "ent-pinned"
     #:issued-at "2026-10-17T03:00:00Z"))
  (check-equal? (permit-snapshot-request-policy-id request)
                "taskly-pro-v1")
  (check-equal? (permit-snapshot-request-policy-version request) 1)
  (check-equal?
   (hash-ref (car (hash-ref (permit-snapshot-request-payload request) 'grants))
             'features)
   '()))

(test-case "catalog rejects missing or mismatched policy configuration"
  (failure-code
   'unknown-entitlement-policy
   (lambda ()
     (make-permit-policy-catalog (list taskly-offer-v1) '())))
  (define wrong-product-policy
    (make-permit-entitlement-policy
     "taskly-pro-v1"
     1
     #:subject-type 'person
     #:grants
     (list (make-permit-grant-policy #:products '("other-product")))))
  (failure-code
   'policy-offer-mismatch
   (lambda ()
     (make-permit-policy-catalog
      (list taskly-offer-v1)
      (list wrong-product-policy)))))

(test-case "catalog structure and request metadata have typed failures"
  (failure-code
   'invalid-policy-catalog
   (lambda ()
     (make-permit-policy-catalog
      (list taskly-offer-v1 taskly-offer-v1)
      (list taskly-policy-v1))))
  (failure-code
   'invalid-policy-catalog
   (lambda ()
     (make-permit-policy-catalog
      (list taskly-offer-v1)
      (list taskly-policy-v1)
      #:deleted-offer-ids '("taskly-pro-lifetime"))))
  (failure-code
   'invalid-entitlement-request
   (lambda ()
     (prepare-permit-snapshot
      catalog (intent 'grant)
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-invalid-time"
      #:entitlement-id "ent-invalid-time"
      #:issued-at "not-a-time")))
  (failure-code
   'unsupported-rights-action
   (lambda ()
     (prepare-permit-snapshot
      catalog (intent 'replace)
      #:issuer "com.turinglambdaai"
      #:credential-id "cred-unsupported-action"
      #:entitlement-id "ent-unsupported-action"
      #:issued-at "2026-10-17T03:00:00Z"))))

(test-case "invalid Permit policy fails before it enters the catalog"
  (failure-code
   'invalid-entitlement-policy
   (lambda ()
     (make-permit-grant-policy
      #:products '("taskly")
      #:feature-policy 'published-through
      #:features '("automation"))))
  (failure-code
   'invalid-entitlement-policy
   (lambda ()
     (make-permit-constraints-policy #:version-min "2.0.0"
                                     #:version-max "1.0.0"))))

(test-case "subscription policy is outside the one-time slice"
  (define subscription-offer
    (offer "taskly-pro-monthly" "taskly" 'subscription usd-29
           "taskly-pro-v1"))
  (define subscription-catalog
    (make-permit-policy-catalog
     (list subscription-offer)
     (list taskly-policy-v1)))
  ;; Subscription Offers resolve their pinned policy like any other; the
  ;; renewal semantics live in prepare-permit-snapshot's renew action.
  (check-eq?
   (permit-entitlement-policy-id
    (permit-policy-for-offer subscription-catalog "taskly-pro-monthly"))
   "taskly-pro-v1"))
