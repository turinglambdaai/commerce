#lang racket/base

(require base64
         commerce
         crypto
         crypto/libcrypto
         json
         commerce/alipay
         rackunit
         racket/string)

;; Generate fixture key material during the test, never commit a private key
;; or accept a string that has not actually passed RSA2 verification.
(define rsa-private-key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))

(define (public-key->pem key)
  (string-append
   "-----BEGIN PUBLIC KEY-----\n"
   (bytes->string/utf-8
    (base64-encode (pk-key->datum key 'SubjectPublicKeyInfo) #:line #f))
   "\n-----END PUBLIC KEY-----\n"))

(define public-key
  (public-key->pem (pk-key->public-only-key rsa-private-key)))

(define unsigned-fields
  (list (cons "total_amount" "12.34")
        (cons "seller_id" "2088000000000000")
        (cons "out_trade_no" "order_test_001")
        (cons "app_id" "2026000000000000")
        (cons "notify_id" "notify_test_001")
        (cons "trade_no" "202610301234567890")
        (cons "trade_status" "TRADE_SUCCESS")
        (cons "sign_type" "RSA2")))

(define signed-fields
  (cons
   (cons "sign"
         (bytes->string/utf-8
          (base64-encode
           (parameterize ([crypto-factories (list libcrypto-factory)])
             (digest/sign rsa-private-key 'sha256
                          (string->bytes/utf-8
                           (alipay-signing-content unsigned-fields))
                          #:pad 'pkcs1-v1.5))
           #:line #f)))
   unsigned-fields))

(define (code? code)
  (lambda (e)
    (and (exn:fail:commerce? e)
         (eq? (exn:fail:commerce-code e) code))))

(define binding
  (alipay-binding "2026000000000000" "2088000000000000"
                  "order_test_001" "taskly-pro-lifetime"
                  "subject-1" (money "CNY" 1234)))
(define queried
  (alipay-confirmed-order "2026000000000000" "2088000000000000"
                          "order_test_001" "202610301234567890"
                          "TRADE_SUCCESS" 1234))

(test-case "RSA2 fixture and exact canonical representation"
  (check-equal?
   (alipay-signing-content signed-fields)
   (string-append
    "app_id=2026000000000000&notify_id=notify_test_001"
    "&out_trade_no=order_test_001&seller_id=2088000000000000"
    "&total_amount=12.34&trade_no=202610301234567890"
    "&trade_status=TRADE_SUCCESS"))
  (define n (verify-alipay-notification signed-fields public-key))
  (check-equal? (alipay-notification-amount n) 1234)
  (define event
    (confirm-alipay-onetime-payment
     n binding queried
     #:payload-digest (make-string 64 #\a)
     #:occurred-at 1793376000))
  (check-equal? (payment-event-provider event) "alipay")
  (check-equal? (payment-event-offer-id event) "taskly-pro-lifetime")
  (check-equal? (payment-event-subject-id event) "subject-1"))

(test-case "amount parsing is integer and rejects ambiguous spellings"
  (for ([pair (in-list '(("0" . 0) ("0.01" . 1)
                         ("12.3" . 1230) ("12.34" . 1234)))])
    (check-equal? (alipay-cny->fen (car pair)) (cdr pair)))
  (for ([bad '("1.001" "-1" "+1" "01.00" "1e2" "1,00"
               "1.2 " "NaN" "")])
    (check-exn (code? 'alipay-amount-invalid)
               (lambda () (alipay-cny->fen bad)))))

(test-case "duplicate and changed fields fail closed"
  (check-exn (code? 'alipay-duplicate-field)
             (lambda () (verify-alipay-notification
                         (cons (cons "app_id" "evil") signed-fields)
                         public-key)))
  (check-exn (code? 'alipay-signature-invalid)
             (lambda ()
               (verify-alipay-notification
                (map (lambda (p)
                       (if (equal? (car p) "total_amount")
                           (cons "total_amount" "12.35") p))
                     signed-fields)
                public-key)))
  (check-exn (code? 'alipay-signature-invalid)
             (lambda ()
               (verify-alipay-notification
                (map (lambda (p)
                       (if (equal? (car p) "sign_type")
                           (cons "sign_type" "MD5") p))
                     signed-fields)
                public-key))))

(test-case "an authenticated notification without matching query cannot pay"
  (define n (verify-alipay-notification signed-fields public-key))
  (for ([bad (list
              (alipay-confirmed-order "other-app" "2088000000000000"
                                      "order_test_001" "202610301234567890"
                                      "TRADE_SUCCESS" 1234)
              (alipay-confirmed-order "2026000000000000" "2088000000000000"
                                      "order_test_001" "202610301234567890"
                                      "WAIT_BUYER_PAY" 1234)
              (alipay-confirmed-order "2026000000000000" "2088000000000000"
                                      "order_test_001" "other-trade"
                                      "TRADE_SUCCESS" 1234)
              (alipay-confirmed-order "2026000000000000" "2088000000000000"
                                      "order_test_001" "202610301234567890"
                                      "TRADE_SUCCESS" 1235))])
    (check-exn (code? 'alipay-order-mismatch)
               (lambda ()
                 (confirm-alipay-onetime-payment
                  n binding bad
                  #:payload-digest (make-string 64 #\a)
                  #:occurred-at 1793376000)))))

(test-case "HTTP form parser preserves UTF-8, plus, escape and duplicates"
  (check-equal? (parse-alipay-form #"a=hello+world&b=%E4%B8%AD&c=a%2Bb")
                (list (cons "a" "hello world")
                      (cons "b" "中")
                      (cons "c" "a+b")))
  (check-exn (code? 'alipay-duplicate-field)
             (lambda () (parse-alipay-form #"app_id=good&app_id=evil")))
  (for ([bad (list #"" #"noequals" #"a=1&" #"a=%FG"
                    #"a=%E4%B8" #"a=%")])
    (check-exn (code? 'alipay-form-invalid)
               (lambda () (parse-alipay-form bad))))
  (check-exn (code? 'alipay-form-invalid)
             (lambda () (parse-alipay-form (make-bytes 65537 97))))
  (check-exn (code? 'alipay-form-invalid)
             (lambda ()
               (parse-alipay-form
                (string->bytes/utf-8
                 (string-join (make-list 129 "a=1") "&"))))))

(test-case "server-priced gateway page-pay parameters have a valid RSA2 signature"
  (define private-key
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
  (define params
    (make-alipay-page-pay-parameters
     binding private-key
     #:title "Taskly Pro lifetime"
     #:notify-url "https://example.test/payments/alipay/notify"
     #:return-url "https://example.test/orders/return"
     #:timestamp "2026-10-30 12:30:00"))
  (check-equal? (cdr (assoc "method" params)) "alipay.trade.page.pay")
  (define biz (string->jsexpr (cdr (assoc "biz_content" params))))
  (check-equal? (hash-ref biz 'total_amount) "12.34")
  (check-equal? (hash-ref biz 'out_trade_no) "order_test_001")
  (check-true
   (digest/verify
    (pk-key->public-only-key private-key) 'sha256
    (string->bytes/utf-8 (alipay-signing-content params))
    (base64-decode
     (string->bytes/utf-8 (cdr (assoc "sign" params))))
    #:pad 'pkcs1-v1.5))
  (check-exn (code? 'alipay-checkout-invalid)
             (lambda ()
               (make-alipay-page-pay-parameters
                binding private-key #:title "test"
                #:notify-url "http://insecure.test"
                #:return-url "https://example.test/ok"
                #:timestamp "2026-10-30 12:30:00"))))
