#lang racket/base

;; One runnable end-to-end journey over the real protocol boundaries:
;; an authenticated Pancake webhook, an actively verified one-time order,
;; the durable journal and projection, deterministic Permit issuance, and
;; one-time claim fulfillment. The transport is deterministic and the keys
;; are generated at run time, so the journey is reproducible everywhere;
;; the runbook (docs/runbook.md) describes the live sandbox drill.

(require base64
         commerce
         commerce/issuer
         commerce/journal
         commerce/operator
         commerce/pancake
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         (only-in crypto crypto-factories digest/sign generate-private-key get-pk pk-key->datum pk-key->public-only-key)
         crypto/libcrypto
         file/sha1
         json
         permit/envelope
         permit/issuer
         racket/file
         racket/port
         racket/string)

(parameterize ([crypto-factories (list libcrypto-factory)])

  (define (pem label key-datum)
    (define encoded
      (bytes->string/utf-8 (base64-encode key-datum #:line #f)))
    (string-append
     "-----BEGIN " label "-----\n"
     (string-join (regexp-match* #px".{1,64}" encoded) "\n")
     "\n-----END " label "-----\n"))

  ;; Provider-side trust: Pancake test-webhook keys and a merchant RSA key.
  (define webhook-private-key
    (generate-private-key (get-pk 'rsa) '((nbits 2048))))
  (define webhook-public-key-pem
    (pem "PUBLIC KEY"
         (pk-key->datum
          (pk-key->public-only-key webhook-private-key)
          'SubjectPublicKeyInfo)))
  ;; A distinct second key stands in for the production environment.
  (define production-webhook-public-key-pem
    (pem "PUBLIC KEY"
         (pk-key->datum
          (pk-key->public-only-key
           (generate-private-key (get-pk 'rsa) '((nbits 2048))))
          'SubjectPublicKeyInfo)))
  (define merchant-private-key-pem
    (pem "PRIVATE KEY" (pk-key->datum webhook-private-key 'OneAsymmetricKey)))

  ;; Commerce-side trust: the Permit issuer keypair and its trust store.
  (define-values (issuer-private-key issuer-public-key)
    (generate-ed25519-keypair))
  (define issuer-name "com.example.journey")
  (define key-id "journey-2026")
  (define trust-store
    (jsexpr->trust-store
     (hasheq 'protocol "permit-trust-store"
             'version 1
             'issuer issuer-name
             'keys
             (hasheq 'journey-2026
                     (hasheq 'algorithm "Ed25519"
                             'public_key
                             (public-key->base64 issuer-public-key)
                             'status "active"
                             'purposes '("entitlement")
                             'not_before 'null
                             'not_after 'null)))))

  ;; The reviewed, version-pinned Offer policy.
  (define catalog
    (make-permit-policy-catalog
     (list (offer "taskly-pro-lifetime" "taskly" 'one-time
                  (money "USD" 2900) "taskly-pro-v1"))
     (list
      (make-permit-entitlement-policy
       "taskly-pro-v1" 1
       #:subject-type 'person
       #:grants
       (list (make-permit-grant-policy
              #:products '("taskly") #:edition "pro"))))))

  ;; 1. An authenticated order.completed webhook over exact bytes.
  (define webhook-body
    (jsexpr->bytes
     (hash 'id "evt_journey_001"
           'timestamp "2026-10-21T00:00:00.000Z"
           'eventType "order.completed"
           'eventId "PAY_journey_001"
           'storeId "STO_journey_001"
           'storeName "Journey Store"
           'data (hash 'orderId "ORD_journey_001")
           'mode "test")))
  (define signed-at-ms 1792108800000)
  (define webhook-signature
    (digest/sign webhook-private-key 'sha256
                 (bytes-append #"1792108800000." webhook-body)
                 #:pad 'pkcs1-v1.5))
  (define webhook
    (verify-pancake-webhook
     webhook-body
     (string-append
      "t=1792108800000,v1="
      (bytes->string/utf-8
       (base64-encode webhook-signature #:line #f)))
     #:environment 'test
     #:keyring (pancake-webhook-keyring
                webhook-public-key-pem
                production-webhook-public-key-pem)
     #:now-ms (+ signed-at-ms 1000)))
  (printf "1. webhook authenticated: order ~a, payment ~a\n"
          (hash-ref (pancake-webhook-data webhook) 'orderId)
          (pancake-webhook-event-id webhook))

  ;; 2. The server-side checkout binding made with checkout, and the
  ;;    actively verified one-time order read (deterministic transport).
  (define binding
    (pancake-order-binding
     "checkout-journey-001" "PROD_journey_001" "taskly-pro-lifetime"
     "customer-journey-001" (money "USD" 2900) 2))
  (define client
    (make-pancake-merchant-client
     "MER_journey001" merchant-private-key-pem
     #:environment 'test
     #:clock (lambda () 1792108800)
     #:transport
     (lambda (endpoint headers body connect-timeout request-timeout)
       (values
        200
        (jsexpr->bytes
         (hash 'data
              (hash 'onetimeOrder
                    (hash 'id "ORD_journey_001"
                          'status "completed"
                          'testMode #t
                          'currency "USD"
                          'orderMerchantExternalId "checkout-journey-001"
                          'store (hash 'id "STO_journey_001")
                          'onetimeProduct (hash 'id "PROD_journey_001")
                          'payments
                          (list
                           (hash 'id "PAY_journey_001"
                                 'status "succeeded"
                                 'snapshotAmountDetails
                                 (hash 'currency "USD" 'total "29.00")))))))))))
  (define paid
    (verify-pancake-onetime-order client webhook binding))
  (printf "2. order verified: canonical event for ~a\n"
          (payment-event-order-id paid))

  ;; 3. Durable acceptance and projection.
  (define directory (make-temporary-directory))
  (define storage
    (open-sqlite-commerce-storage (build-path directory "journey.sqlite")))
  (define acceptance
    (journal-accept! storage
                     (pancake-webhook-raw-body webhook) paid
                     #:received-at 1792108810))
  (storage-project-next! storage #:processed-at 1792108820)
  (printf "3. journal ~a, order projected\n"
          (journal-acceptance-disposition acceptance))

  ;; 4. Deterministic issuance signs the exact recorded bytes and records
  ;;    the revision, the signed envelope, and a one-time claim atomically.
  (define journey-clock (box 1792108830))
  (define (journey-time)
    (values (unbox journey-clock) "2026-10-21T00:00:30Z"))
  (define issuance
    (make-issuance-worker
     #:catalog catalog
     #:issuer issuer-name
     #:private-key issuer-private-key
     #:key-id key-id
     #:trust-store trust-store
     #:clock journey-time))
  (define result (process-issuance-work! issuance storage))
  (define claim-token (issuance-result-claim-token result))
  (printf "4. issuance ~a: revision ~a of ~a\n"
          (issuance-result-disposition result)
          (issuance-result-revision result)
          (issuance-result-entitlement-id result))

  ;; 5. The customer fulfills the one-time claim and receives the exact
  ;;    signed credential bytes.
  (storage-mark-claim-notified storage #:token claim-token #:now 1792108840)
  (define fulfillment
    (storage-claim-credential storage
                              #:token claim-token
                              #:now 1792108850))
  (define credential
    (claim-fulfillment-credential fulfillment))
  (define delivered
    (read-envelope
     (open-input-bytes
      (issued-credential-record-envelope-bytes credential))))
  (printf "5. claim fulfilled: credential ~a verifies ~a\n"
          (issued-credential-record-credential-id credential)
          (if (verify-envelope-signature delivered issuer-public-key)
              'true 'false))

  ;; 6. A refund records commercial evidence as an issuance-expiring
  ;;    successor; the operator surface explains the whole story.
  (define refund-payload
    (jsexpr->bytes
     (hash 'kind "payment-refunded" 'orderId "ORD_journey_001")))
  (journal-accept!
   storage refund-payload
   (make-verified-payment-event
    "pancake" "evt_journey_refund"
    (bytes->hex-string (sha256-bytes refund-payload))
    'payment-refunded "ORD_journey_001" "taskly-pro-lifetime"
    "customer-journey-001" (money "USD" 2900) 1792108900)
   #:received-at 1792108910)
  (storage-project-next! storage #:processed-at 1792108920)
  (set-box! journey-clock 1792108930)
  (define withdrawal (process-issuance-work! issuance storage))
  (printf "6. refund: withdrawal revision ~a expires at issuance\n"
          (issuance-result-revision withdrawal))

  (define explanation (explain-order storage "pancake" "ORD_journey_001"))
  (printf "7. explanation: ~a events, ~a work items, ~a credentials\n"
          (length (order-explanation-events explanation))
          (length (order-explanation-work explanation))
          (length (filter values (order-explanation-credentials explanation))))

  (storage-close storage)
  (delete-directory/files directory))
