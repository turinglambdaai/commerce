#lang racket/base

(require base64
         commerce
         commerce/pancake
         crypto
         crypto/libcrypto
         json
         rackunit
         racket/file
         racket/list
         racket/match
         racket/port
         racket/runtime-path
         racket/string)

(define-runtime-path fixture-root "fixtures/pancake")

(define (fixture-bytes name)
  (file->bytes (build-path fixture-root name)))

(define (fixture-string name)
  (string-trim
   (file->string (build-path fixture-root name))))

(define fixture-keyring
  (pancake-webhook-keyring
   (fixture-string "test-public.pem")
   (fixture-string "production-public.pem")))

(define valid-body (fixture-bytes "order-completed.json"))
(define valid-header (fixture-string "valid-signature.txt"))
(define signed-at 1792108800000)

(define (verify body header
                #:environment [environment 'test]
                #:now-ms [now-ms signed-at])
  (verify-pancake-webhook
   body
   header
   #:environment environment
   #:keyring fixture-keyring
   #:now-ms now-ms))

(define (commerce-code? code)
  (lambda (failure)
    (and (exn:fail:commerce? failure)
         (eq? (exn:fail:commerce-code failure) code))))

(test-case "valid fixture verifies exact raw bytes"
  (define webhook (verify valid-body valid-header))
  (check-equal? (pancake-webhook-id webhook) "evt_fixture_001")
  (check-equal? (pancake-webhook-event-id webhook) "PAY_fixture_001")
  (check-equal? (pancake-webhook-event-type webhook) "order.completed")
  (check-equal? (pancake-webhook-store-id webhook) "STO_fixture_001")
  (check-equal? (pancake-webhook-store-name webhook) "Fixture Store")
  (check-equal? (pancake-webhook-timestamp webhook)
                "2026-10-16T00:00:00.000Z")
  (check-equal? (hash-ref (pancake-webhook-data webhook) 'orderId)
                "ORD_fixture_001")
  (check-eq? (pancake-webhook-environment webhook) 'test)
  (check-equal? (pancake-webhook-signature-timestamp-ms webhook) signed-at)
  (check-equal? (pancake-webhook-raw-body webhook) valid-body)
  (check-equal? (pancake-webhook-payload-digest webhook)
                "b1fb12d1375c954f89240f32da6691d326d1eac472577cd3d206c9ed53bbe03b"))

(test-case "verified bytes are isolated from caller mutation"
  (define mutable-body (bytes-copy valid-body))
  (define webhook (verify mutable-body valid-header))
  (bytes-set! mutable-body 0 (char->integer #\space))
  (check-equal? (pancake-webhook-raw-body webhook) valid-body))

(test-case "changed raw body fails before JSON interpretation"
  (define changed
    (bytes-append (subbytes valid-body 0 (sub1 (bytes-length valid-body)))
                  #" \n"))
  (check-exn (commerce-code? 'pancake-signature-invalid)
             (lambda () (verify changed valid-header))))

(test-case "captured invalid signature fails closed without leaking payload"
  (define invalid-header (fixture-string "invalid-signature.txt"))
  (with-handlers ([exn:fail:commerce?
                   (lambda (failure)
                     (check-eq? (exn:fail:commerce-code failure)
                                'pancake-signature-invalid)
                     (check-false
                      (string-contains? (exn-message failure)
                                        "ORD_fixture_001"))
                     (check-false
                      (string-contains?
                       (format "~s" (exn:fail:commerce-data failure))
                       "ORD_fixture_001")))])
    (verify valid-body invalid-header)
    (fail "invalid signature was accepted")))

(test-case "header parser rejects missing malformed and duplicate fields"
  (for ([header (in-list
                 '(""
                   "garbage"
                   "t=1792108800000"
                   "v1=abc"
                   "t=1792108800000,t=1792108800001,v1=abc"
                   "t=1792108800000,v1=abc,v1=def"))])
    (check-exn
     (commerce-code?
      (if (string=? header "")
          'pancake-signature-header-missing
          'pancake-signature-header-malformed))
     (lambda () (verify valid-body header)))))

(test-case "header parser accepts provider whitespace and extension fields"
  (define extended
    (string-append
     "future=value, t=1792108800000 , v1= "
     (substring valid-header
                (string-length "t=1792108800000,v1="))))
  (check-equal? (pancake-webhook-id (verify valid-body extended))
                "evt_fixture_001"))

(test-case "timestamp window covers retries but rejects stale capture"
  (check-equal?
   (pancake-webhook-id
    (verify valid-body valid-header
            #:now-ms (+ signed-at (* 31 60 1000))))
   "evt_fixture_001")
  (check-exn
   (commerce-code? 'pancake-timestamp-outside-tolerance)
   (lambda ()
     (verify valid-body valid-header
             #:now-ms (+ signed-at (* 45 60 1000) 1)))))

(test-case "timestamp window permits small clock skew but rejects far future"
  (check-equal?
   (pancake-webhook-id
    (verify valid-body valid-header #:now-ms (- signed-at 30000)))
   "evt_fixture_001")
  (check-exn
   (commerce-code? 'pancake-timestamp-outside-tolerance)
   (lambda ()
     (verify valid-body valid-header #:now-ms (- signed-at 60001)))))

(test-case "invalid timestamp is rejected before cryptography"
  (check-exn
   (commerce-code? 'pancake-timestamp-invalid)
   (lambda () (verify valid-body "t=not-a-number,v1=abc"))))

(test-case "test signature cannot cross the production key boundary"
  (check-exn
   (commerce-code? 'pancake-signature-invalid)
   (lambda ()
     (verify valid-body valid-header #:environment 'production))))

(test-case "signed envelope mode must match the selected environment"
  (check-exn
   (commerce-code? 'pancake-environment-mismatch)
   (lambda ()
     (verify (fixture-bytes "mode-mismatch.json")
             (fixture-string "mode-mismatch-signature.txt")))))

(test-case "signed envelope rejects duplicate top-level security fields"
  (define duplicate-keyring
    (pancake-webhook-keyring
     (fixture-string "duplicate-public.pem")
     (fixture-string "production-public.pem")))
  (check-exn
   (commerce-code? 'pancake-payload-invalid)
   (lambda ()
     (verify-pancake-webhook
      (fixture-bytes "duplicate-security-field.json")
      (fixture-string "duplicate-signature.txt")
      #:environment 'test
      #:keyring duplicate-keyring
      #:now-ms signed-at))))

(test-case "invalid configured public key fails with a typed redacted error"
  (define invalid-keyring
    (pancake-webhook-keyring
     "not a public key"
     (fixture-string "production-public.pem")))
  (check-exn
   (commerce-code? 'pancake-public-key-invalid)
   (lambda ()
     (verify-pancake-webhook
      valid-body valid-header
      #:environment 'test
      #:keyring invalid-keyring
      #:now-ms signed-at))))

(test-case "argument errors redact raw bodies and signature headers"
  (with-handlers ([exn:fail:contract?
                   (lambda (failure)
                     (check-false
                      (string-contains? (exn-message failure)
                                        "ORD_fixture_001")))])
    (verify-pancake-webhook
     (bytes->string/utf-8 valid-body) valid-header
     #:environment 'test
     #:keyring fixture-keyring
     #:now-ms signed-at)
    (fail "a string body was accepted"))
  (with-handlers ([exn:fail:contract?
                   (lambda (failure)
                     (check-false
                      (string-contains? (exn-message failure)
                                        "Dm0/yvYUlGDi")))])
    (verify-pancake-webhook
     valid-body (string->bytes/utf-8 valid-header)
     #:environment 'test
     #:keyring fixture-keyring
     #:now-ms signed-at)
    (fail "a byte-string signature header was accepted")))

(test-case "default clock path reports a typed timestamp failure"
  (check-exn
   (commerce-code? 'pancake-timestamp-outside-tolerance)
   (lambda ()
     (verify-pancake-webhook
      valid-body valid-header
      #:environment 'test
      #:keyring fixture-keyring))))

(test-case "keyring requires separate non-empty environment keys"
  (define test-key (fixture-string "test-public.pem"))
  (check-exn exn:fail:contract?
             (lambda () (pancake-webhook-keyring "" test-key)))
  (check-exn exn:fail:contract?
             (lambda () (pancake-webhook-keyring test-key test-key)))
  (check-exn
   exn:fail:contract?
   (lambda ()
     (pancake-webhook-keyring
      test-key
      (string-replace test-key "\n" "\r\n")))))

;; Active order verification uses a generated key and a deterministic transport.
;; No merchant credential or live Pancake response is committed to the package.
(define merchant-private-key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))

(define (key-datum->pem label bytes)
  (define encoded
    (bytes->string/utf-8
     (base64-encode bytes #:line #f)))
  (string-append
   "-----BEGIN " label "-----\n"
   (string-join (regexp-match* #px".{1,64}" encoded) "\n")
   "\n-----END " label "-----\n"))

(define (private-key->pem key)
  (key-datum->pem "PRIVATE KEY" (pk-key->datum key 'OneAsymmetricKey)))

(define merchant-private-key-pem (private-key->pem merchant-private-key))
(define merchant-public-key
  (pk-key->public-only-key merchant-private-key))
(define merchant-public-key-pem
  (key-datum->pem "PUBLIC KEY"
                  (pk-key->datum merchant-public-key 'SubjectPublicKeyInfo)))

(define (signed-test-webhook event-type
                             #:timestamp
                             [timestamp "2026-10-16T00:00:00.000Z"]
                             #:data [data (hash 'orderId "ORD_fixture_001")])
  (define body
    (jsexpr->bytes
     (hash 'id "evt_dynamic_001"
           'timestamp timestamp
           'eventType event-type
           'eventId "PAY_fixture_001"
           'storeId "STO_fixture_001"
           'storeName "Fixture Store"
           'data data
           'mode "test")))
  (define signed-bytes
    (bytes-append #"1792108800000." body))
  (define signature
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign merchant-private-key 'sha256 signed-bytes
                   #:pad 'pkcs1-v1.5)))
  (verify-pancake-webhook
   body
   (string-append
    "t=1792108800000,v1="
    (bytes->string/utf-8 (base64-encode signature #:line #f)))
   #:environment 'test
   #:keyring
   (pancake-webhook-keyring merchant-public-key-pem
                            (fixture-string "production-public.pem"))
   #:now-ms signed-at))

(define default-binding
  (pancake-order-binding
   "commerce-checkout-fixture-001"
   "PROD_fixture_001"
   "taskly-pro-lifetime"
   "subject-fixture-001"
   (money "USD" 2900)
   2))

(define (order-response
         #:order-id [order-id "ORD_fixture_001"]
         #:status [status "completed"]
         #:test-mode [test-mode #t]
         #:order-currency [order-currency "USD"]
         #:external-id [external-id "commerce-checkout-fixture-001"]
         #:store-id [store-id "STO_fixture_001"]
         #:product-id [product-id "PROD_fixture_001"]
         #:payment-id [payment-id "PAY_fixture_001"]
         #:payment-status [payment-status "succeeded"]
         #:payment-currency [payment-currency "USD"]
         #:payment-total [payment-total "29.00"])
  (jsexpr->bytes
   (hash
    'data
    (hash
     'onetimeOrder
     (hash 'id order-id
           'status status
           'testMode test-mode
           'currency order-currency
           'orderMerchantExternalId external-id
           'store (hash 'id store-id)
           'onetimeProduct (hash 'id product-id)
           'payments
           (list
            (hash 'id payment-id
                  'status payment-status
                  'snapshotAmountDetails
                  (hash 'currency payment-currency
                        'total payment-total))))))))

(define (make-captured-client response-body
                              #:status [status 200]
                              #:environment [environment 'test]
                              #:capture [capture (box #f)])
  (values
   (make-pancake-merchant-client
    "MER_fixture001"
    merchant-private-key-pem
    #:environment environment
    #:clock (lambda () 1792108800)
    #:transport
    (lambda (endpoint headers body connect-timeout request-timeout)
      (set-box! capture
                (list endpoint headers body connect-timeout request-timeout))
      (values status response-body)))
   capture))

(define (verify-order-with-response response-body
                                    #:status [status 200]
                                    #:binding [binding default-binding]
                                    #:environment [environment 'test])
  (define-values (client _capture)
    (make-captured-client response-body
                          #:status status
                          #:environment environment))
  (verify-pancake-onetime-order client (verify valid-body valid-header) binding))

(test-case "active query is signed exactly and yields a canonical payment event"
  (define-values (client capture)
    (make-captured-client (order-response)))
  (define event
    (verify-pancake-onetime-order client (verify valid-body valid-header)
                                  default-binding))
  (check-equal? (payment-event-provider event) "pancake")
  (check-equal? (payment-event-event-id event) "evt_fixture_001")
  (check-eq? (payment-event-kind event) 'payment-succeeded)
  (check-equal? (payment-event-order-id event) "ORD_fixture_001")
  (check-equal? (payment-event-offer-id event) "taskly-pro-lifetime")
  (check-equal? (payment-event-subject-id event) "subject-fixture-001")
  (check-equal? (payment-event-amount event) (money "USD" 2900))
  (check-equal? (payment-event-occurred-at event) 1792108800)

  (match-define
    (list endpoint headers request-body connect-timeout request-timeout)
    (unbox capture))
  (check-equal? endpoint "https://api.waffo.ai/v1/graphql")
  (check-equal? connect-timeout 5)
  (check-equal? request-timeout 10)
  (check-equal? (hash-ref headers 'content-type) "application/json")
  (check-equal? (hash-ref headers 'x-merchant-id) "MER_fixture001")
  (check-equal? (hash-ref headers 'x-timestamp) "1792108800")
  (check-false (hash-has-key? headers 'x-idempotency-key))
  (define request-json (bytes->jsexpr request-body))
  (check-equal? (hash-ref (hash-ref request-json 'variables) 'id)
                "ORD_fixture_001")
  (define body-hash
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest 'sha256 request-body)))
  (define canonical
    (string->bytes/utf-8
     (string-append
      "POST\n/v1/graphql\n1792108800\n"
      (bytes->string/utf-8 (base64-encode body-hash #:line #f)))))
  (define signature
    (base64-decode
     (string->bytes/utf-8 (hash-ref headers 'x-signature))))
  (check-true
   (parameterize ([crypto-factories (list libcrypto-factory)])
     (digest/verify merchant-public-key 'sha256 canonical signature
                    #:pad 'pkcs1-v1.5))))

(test-case "event semantics are rejected before network access"
  (define calls 0)
  (define client
    (make-pancake-merchant-client
     "MER_fixture001"
     merchant-private-key-pem
     #:environment 'test
     #:clock (lambda () 1792108800)
     #:transport
     (lambda _arguments
       (set! calls (add1 calls))
       (values 200 (order-response)))))
  (define wrong-event (signed-test-webhook "refund.succeeded"))
  (check-exn (commerce-code? 'pancake-event-unsupported)
             (lambda ()
               (verify-pancake-onetime-order client wrong-event
                                             default-binding)))
  (check-exn
   (commerce-code? 'pancake-event-timestamp-invalid)
   (lambda ()
     (verify-pancake-onetime-order
      client
      (signed-test-webhook "order.completed"
                           #:timestamp "2026-02-30T00:00:00Z")
      default-binding)))
  (check-exn
   (commerce-code? 'pancake-payload-invalid)
   (lambda ()
     (verify-pancake-onetime-order
      client
      (signed-test-webhook "order.completed" #:data "not-an-object")
      default-binding)))
  (define production-client
    (make-pancake-merchant-client
     "MER_fixture001" merchant-private-key-pem
     #:environment 'production
     #:transport
     (lambda _arguments
       (set! calls (add1 calls))
       (values 200 (order-response)))))
  (check-exn
   (commerce-code? 'pancake-environment-mismatch)
   (lambda ()
     (verify-pancake-onetime-order
      production-client (verify valid-body valid-header) default-binding)))
  (check-equal? calls 0))

(test-case "active order verification rejects every substituted authority field"
  (define cases
    (list
     (cons 'pancake-order-id-mismatch
           (order-response #:order-id "ORD_other"))
     (cons 'pancake-order-status-mismatch
           (order-response #:status "pending"))
     (cons 'pancake-environment-mismatch
           (order-response #:test-mode #f))
     (cons 'pancake-store-mismatch
           (order-response #:store-id "STO_other"))
     (cons 'pancake-order-binding-mismatch
           (order-response #:external-id "commerce-checkout-other"))
     (cons 'pancake-product-mismatch
           (order-response #:product-id "PROD_other"))
     (cons 'pancake-currency-mismatch
           (order-response #:order-currency "EUR"))
     (cons 'pancake-payment-not-found
           (order-response #:payment-id "PAY_other"))
     (cons 'pancake-payment-status-mismatch
           (order-response #:payment-status "pending"))
     (cons 'pancake-currency-mismatch
           (order-response #:payment-currency "EUR"))
     (cons 'pancake-amount-mismatch
           (order-response #:payment-total "29.01"))))
  (for ([case (in-list cases)])
    (check-exn (commerce-code? (car case))
               (lambda () (verify-order-with-response (cdr case))))))

(test-case "display money conversion is exact and exponent-aware"
  (check-equal?
   (payment-event-amount
    (verify-order-with-response (order-response #:payment-total "29")))
   (money "USD" 2900))
  (check-equal?
   (payment-event-amount
    (verify-order-with-response (order-response #:payment-total "29.0")))
   (money "USD" 2900))
  (for ([bad (in-list '("29.000" "1e2" "+29.00" "-1.00" "00.10"))])
    (check-exn
     (commerce-code? 'pancake-amount-invalid)
     (lambda ()
       (verify-order-with-response (order-response #:payment-total bad))))))

(test-case "GraphQL and HTTP failures remain typed and redacted"
  (check-exn
   (commerce-code? 'pancake-order-not-found)
   (lambda ()
     (verify-order-with-response #"{\"data\":{\"onetimeOrder\":null}}")))
  (check-exn
   (commerce-code? 'pancake-order-query-rejected)
   (lambda ()
     (verify-order-with-response
      #"{\"data\":null,\"errors\":[{\"message\":\"sensitive provider detail\"}]}")))
  (check-exn
   (commerce-code? 'pancake-merchant-authentication-failed)
   (lambda () (verify-order-with-response #"{}" #:status 401)))
  (check-exn
   (commerce-code? 'pancake-order-unavailable)
   (lambda () (verify-order-with-response #"{}" #:status 503)))
  (check-exn
   (commerce-code? 'pancake-order-response-invalid)
   (lambda () (verify-order-with-response #"not-json")))
  (check-exn
   (commerce-code? 'pancake-order-response-invalid)
   (lambda ()
     (verify-order-with-response (make-bytes (add1 (* 1024 1024)) 65)))))

(test-case "transport failures are retryable and do not leak causes"
  (define client
    (make-pancake-merchant-client
     "MER_fixture001"
     merchant-private-key-pem
     #:environment 'test
     #:transport
     (lambda _arguments
       (error 'transport "secret endpoint detail ORD_fixture_001"))))
  (with-handlers ([exn:fail:commerce?
                   (lambda (failure)
                     (check-eq? (exn:fail:commerce-code failure)
                                'pancake-order-unavailable)
                     (check-true
                      (hash-ref (exn:fail:commerce-data failure) 'retryable?))
                     (check-false
                      (string-contains? (exn-message failure)
                                        "ORD_fixture_001"))
                     (check-false
                      (string-contains?
                       (format "~s" (exn:fail:commerce-data failure))
                       "ORD_fixture_001")))])
    (verify-pancake-onetime-order client (verify valid-body valid-header)
                                  default-binding)
    (fail "transport failure was accepted")))

(test-case "merchant client rejects invalid credentials without echoing secrets"
  (check-exn exn:fail:contract?
             (lambda ()
               (make-pancake-merchant-client
                "not-a-merchant" merchant-private-key-pem
                #:environment 'test)))
  (with-handlers ([exn:fail:commerce?
                   (lambda (failure)
                     (check-eq? (exn:fail:commerce-code failure)
                                'pancake-merchant-private-key-invalid)
                     (check-false
                      (string-contains? (exn-message failure) "not-secret")))])
    (make-pancake-merchant-client
     "MER_fixture001" "not-secret" #:environment 'test)
    (fail "invalid private key was accepted")))

(test-case "binding validates money scale and stable identifiers"
  (check-exn exn:fail:contract?
             (lambda ()
               (pancake-order-binding
                "binding" "PROD_x" "Not Stable" "subject"
                (money "USD" 100) 2)))
  (check-exn exn:fail:contract?
             (lambda ()
               (pancake-order-binding
                "binding" "PROD_x" "stable-offer" "subject"
                (money "USD" 100) 5))))
