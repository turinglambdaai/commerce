#lang racket/base

(require base64
         commerce
         commerce/alipay
         crypto
         crypto/libcrypto
         json
         rackunit
         racket/list
         racket/string)

(define test-private
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
(define test-public (pk-key->public-only-key test-private))

(define (pem label data)
  (define encoded (bytes->string/utf-8 (base64-encode data #:line #f)))
  (string-append "-----BEGIN " label "-----\n"
                 (string-join (regexp-match* #px".{1,64}" encoded) "\n")
                 "\n-----END " label "-----\n"))
(define private-pem
  (pem "PRIVATE KEY" (pk-key->datum test-private 'OneAsymmetricKey)))
(define public-pem
  (pem "PUBLIC KEY"
       (pk-key->datum test-public 'SubjectPublicKeyInfo)))

(define binding
  (make-alipay-order-binding
   "order_001" "taskly-pro-lifetime" "subject-test-001"
   (money "CNY" 1990) "test-app-01" "test-seller-01"))

(define (bad-code? code)
  (lambda (failure)
    (and (exn:fail:commerce? failure)
         (eq? (exn:fail:commerce-code failure) code))))

(define hex-digits "0123456789ABCDEF")
(define (escape-form text)
  (apply string-append
         (for/list ([b (in-bytes (string->bytes/utf-8 text))])
           (define ch (integer->char b))
           (if (regexp-match? #px"^[A-Za-z0-9_.~-]$" (string ch))
               (string ch)
               (string #\%
                       (string-ref hex-digits (quotient b 16))
                       (string-ref hex-digits (remainder b 16)))))))
(define (form-encode pairs)
  (string->bytes/utf-8
   (string-join
    (for/list ([(k v) (in-hash pairs)])
      (string-append (escape-form k) "=" (escape-form v)))
    "&")))

(define (signed-form fields #:key [key test-private])
  (define message
    (string->bytes/utf-8 (alipay-canonical-parameters fields)))
  (define sig
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign key 'sha256 message #:pad 'pkcs1-v1.5)))
  (form-encode
   (hash-set fields "sign"
             (bytes->string/utf-8 (base64-encode sig #:line #f)))))

(define notification-fields
  (hash "sign_type" "RSA2"
        "app_id" "test-app-01"
        "seller_id" "test-seller-01"
        "out_trade_no" "order_001"
        "total_amount" "19.90"
        "trade_status" "TRADE_SUCCESS"
        "trade_no" "alipay_trade_001"
        "notify_id" "notice_001"
        "notify_type" "trade_status_sync"
        "subject" "Taskly Pro"))

(test-case "strict CNY minor-unit conversion, never floating point"
  (check-equal? (alipay-cny->text (money "CNY" 1)) "0.01")
  (check-equal? (alipay-cny->text (money "CNY" 1990)) "19.90")
  (check-equal? (alipay-parse-cny "19.9") (money "CNY" 1990))
  (check-equal? (alipay-parse-cny "19.90") (money "CNY" 1990))
  (for ([bad '("0" "0.00" "19.901" "1e3" "-1" "NaN" "001.00"
               "100000000.01" "100000001" "1,99")])
    (check-exn (bad-code? 'alipay-amount-invalid)
               (lambda () (alipay-parse-cny bad)))))

(test-case "reject duplicate fields and malformed percent-encoding before signing"
  (check-exn (bad-code? 'alipay-form-invalid)
             (lambda () (alipay-decode-form #"sign=abc&sign=def")))
  (check-exn (bad-code? 'alipay-form-invalid)
             (lambda () (alipay-decode-form #"a=1&%61=2")))
  (check-exn (bad-code? 'alipay-form-invalid)
             (lambda () (alipay-decode-form #"a=1&x=%Q0")))
  (check-exn (bad-code? 'alipay-form-invalid)
             (lambda () (alipay-decode-form #"a=%FF")))
  (check-exn (bad-code? 'alipay-form-invalid)
             (lambda () (alipay-decode-form (make-bytes 70000 97)))))

(test-case "signature sorting uses decoded form fields and ignores sign fields"
  (check-equal?
   (alipay-canonical-parameters
    (hash "z" "2" "a" "中文" "sign" "discard" "sign_type" "RSA2"))
   "a=中文&z=2")
  (check-equal?
   (alipay-decode-form #"name=%E4%B8%AD%E6%96%87&plus=a%2Bb&space=a+b")
   (hash "name" "中文" "plus" "a+b" "space" "a b")))

(test-case "valid signed notice is opaque but is not verified payment evidence"
  (define signed (signed-form notification-fields))
  (define notice (verify-alipay-notification signed binding public-pem))
  (check-true (alipay-notification? notice))
  (check-false (payment-event? notice))
  (check-equal? (alipay-notification-notify-id notice) "notice_001")
  (check-equal? (alipay-notification-order-id notice) "order_001")
  (check-equal? (alipay-notification-trade-no notice) "alipay_trade_001")
  (check-equal? (alipay-notification-amount notice) (money "CNY" 1990))
  (check-equal? (string-length (alipay-notification-payload-digest notice)) 64)
  (check-false (string-contains? (format "~s" notice) "test-seller-01")))

(test-case "signed notice with altered bytes, wrong key, order, amount or app fails closed"
  (define signed (signed-form notification-fields))
  (define other-key
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
  (define wrong-public
    (pem "PUBLIC KEY"
         (pk-key->datum (pk-key->public-only-key other-key)
                        'SubjectPublicKeyInfo)))
  (check-exn (bad-code? 'alipay-signature-invalid)
             (lambda () (verify-alipay-notification signed binding wrong-public)))
  (check-exn (bad-code? 'alipay-signature-invalid)
             (lambda () (verify-alipay-notification
                         (bytes-append signed #"&unexpected=x") binding public-pem)))
  (for ([fields (list (hash-set notification-fields "app_id" "other-app")
                     (hash-set notification-fields "seller_id" "other-seller")
                     (hash-set notification-fields "out_trade_no" "other_order")
                     (hash-set notification-fields "total_amount" "19.91"))])
    (check-exn (bad-code? 'alipay-order-mismatch)
               (lambda () (verify-alipay-notification
                           (signed-form fields) binding public-pem))))
  (check-exn (bad-code? 'alipay-not-paid)
             (lambda ()
               (verify-alipay-notification
                (signed-form
                 (hash-set notification-fields "trade_status" "WAIT_BUYER_PAY"))
                binding public-pem)))
  (check-exn (bad-code? 'alipay-signature-invalid)
             (lambda ()
               (verify-alipay-notification
                (signed-form
                 (hash-set notification-fields "sign_type" "RSA"))
                binding public-pem))))

(test-case "Alipay callback variants cannot be confused with a first payment"
  (for ([f (list (hash-set notification-fields "refund_fee" "1.00")
                 (hash-set notification-fields "out_biz_no" "refund_001")
                 (hash-set notification-fields "gmt_refund" "2026-10-30 10:00:00"))])
    (check-exn (bad-code? 'alipay-refund-unsupported)
               (lambda () (verify-alipay-notification
                           (signed-form f) binding public-pem))))
  (check-exn (bad-code? 'alipay-order-mismatch)
             (lambda () (verify-alipay-notification
                         (signed-form
                          (hash-set notification-fields "auth_app_id"
                                    "different-app"))
                         binding public-pem)))
  (check-exn (bad-code? 'alipay-notification-invalid)
             (lambda () (verify-alipay-notification
                         (signed-form
                          (hash-set notification-fields "notify_type"
                                    "fund_auth_freeze"))
                         binding public-pem))))

(test-case "page-pay request signs canonical fields and uses a server-bound offer"
  (define fields
    (make-alipay-page-pay-parameters
     binding private-pem "Taskly Pro" "2026-10-30 09:00:00"
     "https://example.test/alipay/notify"
     #:return-url "https://example.test/payment/return"))
  (check-equal? (hash-ref fields "method") "alipay.trade.page.pay")
  (check-equal? (hash-ref fields "sign_type") "RSA2")
  (check-equal? (hash-ref fields "notify_url") "https://example.test/alipay/notify")
  (check-equal? (hash-ref fields "return_url") "https://example.test/payment/return")
  (check-equal? (hash-ref (string->jsexpr (hash-ref fields "biz_content"))
                          'out_trade_no) "order_001")
  (check-equal? (hash-ref (string->jsexpr (hash-ref fields "biz_content"))
                          'total_amount) "19.90")
  (define signed-bytes
    (string->bytes/utf-8
     (alipay-canonical-parameters fields #:notification? #f)))
  (check-true
   (parameterize ([crypto-factories (list libcrypto-factory)])
     (digest/verify
      test-public 'sha256 signed-bytes
      (base64-decode (string->bytes/utf-8 (hash-ref fields "sign")))
      #:pad 'pkcs1-v1.5)))
  (check-exn (bad-code? 'alipay-checkout-invalid)
             (lambda () (make-alipay-page-pay-parameters
                         binding private-pem "Taskly / Pro" "2026-10-30 09:00:00"
                         "https://example.test/notify")))
  (check-exn (bad-code? 'alipay-checkout-invalid)
             (lambda () (make-alipay-page-pay-parameters
                         binding private-pem "Taskly Pro" "2026-10-30 09:00:00"
                         "http://example.test/notify"))))
