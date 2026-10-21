#lang racket/base

(require commerce
         commerce/journal
         commerce/pancake
         commerce/provider
         commerce/reconcile
         commerce/storage
         commerce/storage/sqlite
         base64
         crypto
         crypto/libcrypto
         json
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

  (define merchant-private-key-pem
    (pem "PRIVATE KEY"
         (pk-key->datum
          (generate-private-key (get-pk 'rsa) '((nbits 2048)))
          'OneAsymmetricKey)))

  (define binding
    (pancake-order-binding
     "checkout-recon-001" "PROD_recon_001" "taskly-pro-lifetime"
     "customer-recon-001" usd-29 2))

  (define (order-response
           #:order-id [order-id "ORD_recon_001"]
           #:status [status "completed"]
           #:payment-status [payment-status "succeeded"])
    (jsexpr->bytes
     (hash 'data
           (hash 'onetimeOrder
                 (hash 'id order-id
                       'status status
                       'testMode #t
                       'currency "USD"
                       'orderMerchantExternalId "checkout-recon-001"
                       'store (hash 'id "STO_recon_001")
                       'onetimeProduct (hash 'id "PROD_recon_001")
                       'payments
                       (list
                        (hash 'id "PAY_recon_001"
                              'status payment-status
                              'snapshotAmountDetails
                              (hash 'currency "USD" 'total "29.00"))))))))

  (define (make-client response-thunk)
    (make-pancake-merchant-client
     "MER_recon001" merchant-private-key-pem
     #:environment 'test
     #:clock (lambda () 1792108800)
     #:transport
     (lambda (endpoint headers body connect-timeout request-timeout)
       (values 200 (response-thunk)))))

  ;; One unique directory per database so rapid calls never share a path.
  (define (call-with-temporary-database proc)
    (define directory
      (make-temporary-file "commerce-reconcile-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (proc (build-path directory "commerce.sqlite")))
      (lambda ()
        (delete-directory/files directory))))

  (define (open-unpaid-storage path)
    (define storage (open-sqlite-commerce-storage path))
    storage)

  (test-case "a provider-paid order with no webhook is a missing-webhook"
    (call-with-temporary-database
     (lambda (path)
       (define storage (open-unpaid-storage path))
       (define client (make-client (lambda () (order-response))))
       (define differences
         (reconcile-orders storage client
                           (list (cons "ORD_recon_001" binding))))
       (check-equal? (length differences) 1)
       (define difference (car differences))
       (check-equal? (reconciliation-difference-order-id difference)
                     "ORD_recon_001")
       (check-eq? (reconciliation-difference-code difference)
                  'missing-webhook)
       ;; Reconciliation never mutates state.
       (check-false (storage-order-ref storage "pancake" "ORD_recon_001"))
       (check-equal?
        (readiness-work-pending
         (storage-readiness storage #:now 100))
        0)
       (storage-close storage))))

  (test-case "matching paid state produces no difference"
    (call-with-temporary-database
     (lambda (path)
       (define payload #"authenticated payment")
       (define storage (open-sqlite-commerce-storage path))
       (journal-accept!
        storage payload
        (make-verified-payment-event
         "pancake" "evt_recon" (bytes->hex-string (sha256-bytes payload))
         'payment-succeeded "ORD_recon_001" "taskly-pro-lifetime"
         "customer-recon-001" usd-29 1792108800)
        #:received-at 10)
       (storage-project-next! storage #:processed-at 11)
       (define client (make-client (lambda () (order-response))))
       (define differences
         (reconcile-orders storage client
                           (list (cons "ORD_recon_001" binding))))
       (check-equal? differences '())
       (storage-close storage))))

  (test-case "an unavailable provider read is skipped, not a difference"
    (call-with-temporary-database
     (lambda (path)
       (define storage (open-unpaid-storage path))
       (define client
         (make-pancake-merchant-client
          "MER_recon001" merchant-private-key-pem
          #:environment 'test
          #:clock (lambda () 1792108800)
          #:transport
          (lambda (endpoint headers body connect-timeout request-timeout)
            (values 503 #"server busy"))))
       (define differences
         (reconcile-orders storage client
                           (list (cons "ORD_recon_001" binding))))
       (check-equal? differences '())
       (storage-close storage))))

  (test-case "a provider order that vanished is reported"
    (call-with-temporary-database
     (lambda (path)
       (define storage (open-unpaid-storage path))
       (define client
         (make-pancake-merchant-client
          "MER_recon001" merchant-private-key-pem
          #:environment 'test
          #:clock (lambda () 1792108800)
          #:transport
          (lambda (endpoint headers body connect-timeout request-timeout)
            (values
             200
             (jsexpr->bytes
              (hash 'data
                    (hash 'onetimeOrder (json-null))))))))
       (define differences
         (reconcile-orders storage client
                           (list (cons "ORD_recon_001" binding))))
       (check-equal? (length differences) 1)
       (check-eq? (reconciliation-difference-code (car differences))
                  'provider-order-not-found)
       (storage-close storage)))))
