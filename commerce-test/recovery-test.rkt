#lang racket/base

;; Scenario-level recovery journeys, one per runbook recovery route
;; (docs/runbook.md): a delayed webhook, a duplicate callback, a lost
;; browser return, and a failed credential import. Each journey walks
;; the one recovery route an operator has and asserts the invariants
;; that make the route safe: the logical order and entitlement are
;; reused, the journal stays idempotent, and one payment event can
;; only ever converge on one credential — never a second charge.

(require commerce
         commerce/issuer
         commerce/operator
         commerce/pancake
         commerce/permit
         commerce/provider
         commerce/reconcile
         commerce/server
         commerce/storage
         commerce/storage/sqlite
         base64
         db
         crypto
         crypto/libcrypto
         json
         permit/envelope
         permit/issuer
         rackunit
         racket/file
         racket/string)

(parameterize ([crypto-factories (list libcrypto-factory)])

  (define usd-29 (money "USD" 2900))

  (define (pem label key-datum)
    (define encoded
      (bytes->string/utf-8 (base64-encode key-datum #:line #f)))
    (string-append
     "-----BEGIN " label "-----\n"
     (string-join (regexp-match* #px".{1,64}" encoded) "\n")
     "\n-----END " label "-----\n"))

  (define webhook-private-key
    (generate-private-key (get-pk 'rsa) '((nbits 2048))))
  (define webhook-public-key-pem
    (pem "PUBLIC KEY"
         (pk-key->datum
          (pk-key->public-only-key webhook-private-key)
          'SubjectPublicKeyInfo)))
  (define production-public-key-pem
    (pem "PUBLIC KEY"
         (pk-key->datum
          (pk-key->public-only-key
           (generate-private-key (get-pk 'rsa) '((nbits 2048))))
          'SubjectPublicKeyInfo)))
  (define merchant-private-key-pem
    (pem "PRIVATE KEY"
         (pk-key->datum webhook-private-key 'OneAsymmetricKey)))

  (define keyring
    (pancake-webhook-keyring webhook-public-key-pem
                             production-public-key-pem))

  (define-values (issuer-private-key issuer-public-key)
    (generate-ed25519-keypair))
  (define issuer-name "com.turinglambdaai")
  (define trust-store
    (jsexpr->trust-store
     (hasheq 'protocol "permit-trust-store"
             'version 1
             'issuer issuer-name
             'keys
             (hasheq 'test-2026
                     (hasheq 'algorithm "Ed25519"
                             'public_key
                             (public-key->base64 issuer-public-key)
                             'status "active"
                             'purposes '("entitlement")
                             'not_before 'null
                             'not_after 'null)))))

  (define catalog
    (make-permit-policy-catalog
     (list (offer "taskly-pro-lifetime" "taskly" 'one-time
                  usd-29 "taskly-pro-v1"))
     (list
      (make-permit-entitlement-policy
       "taskly-pro-v1" 1
       #:subject-type 'person
       #:grants
       (list (make-permit-grant-policy
              #:products '("taskly")))))))

  (define issuance-worker
    (make-issuance-worker
     #:catalog catalog
     #:issuer issuer-name
     #:private-key issuer-private-key
     #:key-id "test-2026"
     #:trust-store trust-store
     #:clock (lambda () (values 100 "2026-10-21T00:00:00Z"))))

  ;; One unique directory per database so rapid calls never share a path.
  (define (call-with-temporary-database proc)
    (define directory
      (make-temporary-file "commerce-recovery-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (proc (build-path directory "commerce.sqlite")))
      (lambda ()
        (delete-directory/files directory))))

  (define (count-rows path sql)
    (define connection (sqlite3-connect #:database path #:mode 'read-only))
    (begin0
      (query-value connection sql)
      (disconnect connection)))

  ;; The full per-scenario harness: checkout binding, HTTP edge, and the
  ;; merchant client whose transport always reports the completed order.
  (define (call-with-journey proc)
    (call-with-temporary-database
     (lambda (path)
       (define storage (open-sqlite-commerce-storage path))
       (storage-create-checkout-binding!
        storage
        (checkout-binding "ORD_rec_001" "pancake" "PROD_rec_001"
                          "taskly-pro-lifetime" "customer-rec-001"
                          "USD" 2900 2)
        #:created-at 1)
       (define client
         (make-pancake-merchant-client
          "MER_rec001" merchant-private-key-pem
          #:environment 'test
          #:clock (lambda () 1792108800)
          #:transport
          (lambda (endpoint headers body connect-timeout request-timeout)
            (values
             200
             (jsexpr->bytes
              (hash 'data
                    (hash 'onetimeOrder
                          (hash 'id "ORD_rec_001"
                                'status "completed"
                                'testMode #t
                                'currency "USD"
                                'orderMerchantExternalId "ORD_rec_001"
                                'store (hash 'id "STO_rec_001")
                                'onetimeProduct (hash 'id "PROD_rec_001")
                                'payments
                                (list
                                 (hash 'id "PAY_rec_001"
                                       'status "succeeded"
                                       'snapshotAmountDetails
                                       (hash 'currency "USD"
                                             'total "29.00")))))))))))
       (define endpoint
         (make-webhook-endpoint
          #:keyring keyring
          #:environment 'test
          #:merchant-client client
          #:binding-lookup
          (lambda (order-id)
            (storage-checkout-binding-ref storage order-id))
          #:storage storage))
       (proc storage client endpoint path))))

  (define (iso-8601 epoch-seconds)
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
     ":" (pad2 (date-second moment)) ".000Z"))

  ;; Webhook fixtures carry a fresh timestamp so they sit inside the
  ;; replay-tolerance window no matter when the suite runs. The signature
  ;; covers the exact bytes, so any two calls with different bodies are
  ;; both individually valid while remaining distinct payloads.
  (define (signed-webhook
           #:event-id [event-id "evt_rec_001"]
           #:store-name [store-name "Recovery Store"])
    (define now-ms (inexact->exact (floor (current-inexact-milliseconds))))
    (define body
      (jsexpr->bytes
       (hash 'id event-id
             'timestamp (iso-8601 (quotient now-ms 1000))
             'eventType "order.completed"
             'eventId "PAY_rec_001"
             'storeId "STO_rec_001"
             'storeName store-name
             'data (hash 'orderId "ORD_rec_001")
             'mode "test")))
    (define signature
      (digest/sign webhook-private-key 'sha256
                   (bytes-append (string->bytes/utf-8
                                  (string-append (number->string now-ms)
                                                 "."))
                                 body)
                   #:pad 'pkcs1-v1.5))
    (values body
            (string-append
             "t=" (number->string now-ms)
             ",v1="
             (bytes->string/utf-8
              (base64-encode signature #:line #f)))))

  (define (parse-json payload)
    (string->jsexpr (bytes->string/utf-8 payload)))

  ;; The recovery harness drives the real worker surfaces by hand: one
  ;; projection pass and one issuance pass per journaled event, exactly
  ;; as the service assembly does between webhook arrivals.
  (define (drive-until-complete storage)
    (storage-project-next! storage #:processed-at 20)
    (define result (process-issuance-work! issuance-worker storage))
    (check-eq? (issuance-result-disposition result) 'completed)
    result)

  (define (assert-single-grant path storage)
    ;; One payment event, one outbox row, one credential, one revision,
    ;; one claim: the whole recovery question reduces to "did the
    ;; journal converge on exactly one grant".
    (check-equal? (count-rows path "SELECT COUNT(*) FROM commerce_event_journal")
                  1)
    (check-equal?
     (count-rows path "SELECT COUNT(*) FROM commerce_issuance_outbox
                       WHERE status = 'completed'")
     1)
    (check-equal?
     (count-rows path "SELECT COUNT(*) FROM commerce_issued_credential")
     1)
    (check-equal?
     (count-rows path "SELECT COUNT(*) FROM commerce_entitlement_revision")
     1)
    (check-equal? (count-rows path "SELECT COUNT(*) FROM commerce_claim")
                  1))

  (test-case "a delayed webhook closes the gap without a second grant"
    (call-with-journey
     (lambda (storage client endpoint path)
       ;; The webhook is late; reconciliation has already surfaced the
       ;; paid order as a missing-webhook difference.
       (define differences
         (reconcile-orders storage client
                           (list (cons "ORD_rec_001"
                                       (pancake-order-binding
                                        "ORD_rec_001" "PROD_rec_001"
                                        "taskly-pro-lifetime"
                                        "customer-rec-001" usd-29 2)))))
       (check-equal? (length differences) 1)
       (check-eq? (reconciliation-difference-code (car differences))
                  'missing-webhook)
       ;; The delayed webhook now arrives through the normal edge and
       ;; follows the ordinary accept, project, issue path.
       (define-values (body header) (signed-webhook))
       (define-values (status payload)
         (handle-webhook-post endpoint body header))
       (check-eq? status 200)
       (check-equal? (hash-ref (parse-json payload) 'disposition)
                     "accepted")
       (drive-until-complete storage)
       ;; The provider's own redelivery of the same webhook is a no-op.
       (define-values (replay-status replay-payload)
         (handle-webhook-post endpoint body header))
       (check-eq? replay-status 200)
       (check-equal? (hash-ref (parse-json replay-payload) 'disposition)
                     "replayed")
       ;; The gap closed on the journal path; no manual state repair.
       (check-equal?
        (reconcile-orders storage client
                          (list (cons "ORD_rec_001"
                                      (pancake-order-binding
                                       "ORD_rec_001" "PROD_rec_001"
                                       "taskly-pro-lifetime"
                                       "customer-rec-001" usd-29 2))))
        null)
       (assert-single-grant path storage)
       (storage-close storage))))

  (test-case "duplicate callbacks converge on one grant"
    (call-with-journey
     (lambda (storage client endpoint path)
       (define-values (body header) (signed-webhook))
       (define-values (status payload)
         (handle-webhook-post endpoint body header))
       (check-eq? status 200)
       (check-equal? (hash-ref (parse-json payload) 'disposition)
                     "accepted")
       ;; The same callback delivered twice is acknowledged without a
       ;; second journal row.
       (define-values (replay-status replay-payload)
         (handle-webhook-post endpoint body header))
       (check-eq? replay-status 200)
       (check-equal? (hash-ref (parse-json replay-payload) 'disposition)
                     "replayed")
       ;; Changed bytes under the same event id are refused and journal
       ;; nothing: investigating the conflict is the only route.
       (define-values (conflict-body conflict-header)
         (signed-webhook #:store-name "A Different Store"))
       (define-values (conflict-status conflict-payload)
         (handle-webhook-post endpoint conflict-body conflict-header))
       (check-eq? conflict-status 409)
       (check-equal? (hash-ref (parse-json conflict-payload) 'error)
                     "conflicting-replay")
       (drive-until-complete storage)
       (assert-single-grant path storage)
       (storage-close storage))))

  (test-case "a lost browser return recovers through provider redelivery"
    (call-with-journey
     (lambda (storage client endpoint path)
       ;; The customer paid but the success page never loaded and the
       ;; webhook was lost: no journal row, no projection.
       (check-false (storage-order-ref storage "pancake" "ORD_rec_001"))
       ;; The product asks reconciliation, which reports the gap by
       ;; comparing a signed provider read with the empty projection.
       (define differences
         (reconcile-orders storage client
                           (list (cons "ORD_rec_001"
                                       (pancake-order-binding
                                        "ORD_rec_001" "PROD_rec_001"
                                        "taskly-pro-lifetime"
                                        "customer-rec-001" usd-29 2)))))
       (check-equal? (length differences) 1)
       (check-eq? (reconciliation-difference-code (car differences))
                  'missing-webhook)
       ;; Reconciliation itself never mutates; the one recovery route is
       ;; provider redelivery of the webhook through the normal edge.
       (define-values (body header) (signed-webhook))
       (define-values (status payload)
         (handle-webhook-post endpoint body header))
       (check-eq? status 200)
       (check-equal? (hash-ref (parse-json payload) 'disposition)
                     "accepted")
       (drive-until-complete storage)
       ;; The same logical order and entitlement were reused, and the
       ;; story is one event, one work item, one credential.
       (define explanation
         (explain-order storage "pancake" "ORD_rec_001"))
       (check-equal? (length (order-explanation-events explanation)) 1)
       (check-equal? (length (order-explanation-work explanation)) 1)
       (check-equal?
        (length (filter values (order-explanation-credentials explanation)))
        1)
       (check-equal?
        (count-rows path
                    "SELECT subject_id FROM commerce_entitlement_lineage")
        "customer-rec-001")
       ;; The reconciliation loop is clean: no difference remains.
       (check-equal?
        (reconcile-orders storage client
                          (list (cons "ORD_rec_001"
                                      (pancake-order-binding
                                       "ORD_rec_001" "PROD_rec_001"
                                       "taskly-pro-lifetime"
                                       "customer-rec-001" usd-29 2))))
        null)
       (assert-single-grant path storage)
       (storage-close storage))))

  (test-case "a failed import reissues the same credential once"
    (call-with-journey
     (lambda (storage client endpoint path)
       ;; The journey runs to a fulfilled claim; the product's import of
       ;; the delivered bytes then fails on the customer machine.
       (define-values (body header) (signed-webhook))
       (define-values (status payload)
         (handle-webhook-post endpoint body header))
       (check-eq? status 200)
       (define result (drive-until-complete storage))
       (define original-token (issuance-result-claim-token result))
       (define fulfillment
         (storage-claim-credential storage
                                   #:token original-token
                                   #:now 150))
       (define credential-id
         (issued-credential-record-credential-id
          (claim-fulfillment-credential fulfillment)))
       ;; The old claim is spent; the operator's one recovery route is a
       ;; reissue: a fresh token for the SAME credential, audited.
       (check-exn
        exn:fail:commerce?
        (lambda ()
          (storage-claim-credential storage
                                    #:token original-token
                                    #:now 160)))
       (define new-claim
         (storage-reissue-claim! storage
                                 #:claim-id 1
                                 #:claim-token "fresh-import-token"
                                 #:expires-at 5200000
                                 #:operator "ops-recovery"
                                 #:reason "credential import failed"
                                 #:now 200))
       (check-eq? (claim-record-status new-claim) 'ready)
       (define retry
         (storage-claim-credential storage
                                   #:token "fresh-import-token"
                                   #:now 250))
       (check-equal?
        (issued-credential-record-credential-id
         (claim-fulfillment-credential retry))
        credential-id)
       (storage-close storage)
       ;; One credential, one revision, two claims, one audited reissue:
       ;; the re-grant never became a second purchase.
       (check-equal?
        (count-rows path "SELECT COUNT(*) FROM commerce_issued_credential")
        1)
       (check-equal?
        (count-rows path "SELECT COUNT(*) FROM commerce_entitlement_revision")
        1)
       (check-equal? (count-rows path "SELECT COUNT(*) FROM commerce_claim")
                     2)
       (check-equal?
        (count-rows path
                    (string-append
                     "SELECT COUNT(*) FROM commerce_operator_audit "
                     "WHERE action = 'reissue-claim'"))
        1))))
)
