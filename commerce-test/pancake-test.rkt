#lang racket/base

(require commerce
         commerce/pancake
         rackunit
         racket/file
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
