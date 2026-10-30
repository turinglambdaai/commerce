#lang racket/base

;; Alipay Vibe Pay "basic collection" uses the regular Alipay RSA2 API.
;; This deliberately does NOT turn a signed callback into product rights:
;; the caller must perform an independently authenticated active trade query
;; and persist the verified fact in the Commerce journal before issuing Permit.
(provide make-alipay-order-binding
         alipay-order-binding?
         alipay-order-binding-out-trade-no
         alipay-order-binding-offer-id
         alipay-order-binding-subject-id
         alipay-order-binding-amount
         alipay-order-binding-app-id
         alipay-order-binding-seller-id
         alipay-notification?
         alipay-notification-notify-id
         alipay-notification-trade-no
         alipay-notification-trade-status
         alipay-notification-order-id
         alipay-notification-payload-digest
         alipay-notification-amount
         alipay-gateway-url
         alipay-cny->text
         alipay-parse-cny
         alipay-canonical-parameters
         alipay-decode-form
         make-alipay-page-pay-parameters
         verify-alipay-notification
         make-alipay-trade-query-parameters
         verified-alipay-trade-query->payment-event)

(require base64
         crypto
         crypto/libcrypto
         crypto/pem
         json
         racket/list
         racket/port
         racket/string
         (only-in "provider.rkt" make-verified-payment-event)
         "private/model.rkt")

(define alipay-gateway-url "https://openapi.alipay.com/gateway.do")
(define max-form-bytes 65536)
(define max-params 128)
(define max-cny-fen (* 100 100000000))

(define (reject code description)
  ;; Never render user-controlled payment bytes, signatures or keys in errors.
  (raise (exn:fail:commerce description (current-continuation-marks)
                            code (hash))))

(define (nonempty? x)
  (and (string? x) (positive? (string-length x))))

(define (valid-order-id? x)
  (and (string? x) (regexp-match? #px"^[A-Za-z0-9_]{1,64}$" x)))

(struct alipay-order-binding
  (out-trade-no offer-id subject-id amount app-id seller-id)
  #:transparent)

(define (make-alipay-order-binding order-id offer-id subject-id amount
                                   app-id seller-id)
  (unless (and (valid-order-id? order-id)
               (stable-id? offer-id)
               (opaque-id? subject-id)
               (money? amount)
               (string=? (money-currency amount) "CNY")
               (<= 1 (money-minor-units amount) max-cny-fen)
               (nonempty? app-id)
               (nonempty? seller-id))
    (reject 'alipay-binding-invalid "invalid Alipay checkout binding"))
  (alipay-order-binding order-id offer-id subject-id amount app-id seller-id))

;; Not a public, forgeable payment-event constructor.
(struct alipay-notification
  (notify-id trade-no trade-status order-id amount payload-digest))

(define (alipay-cny->text value)
  (unless (and (money? value) (string=? (money-currency value) "CNY")
               (<= 1 (money-minor-units value) max-cny-fen))
    (reject 'alipay-amount-invalid "invalid CNY payment amount"))
  (let ([n (money-minor-units value)])
    (string-append (number->string (quotient n 100)) "."
                   (if (< (remainder n 100) 10) "0" "")
                   (number->string (remainder n 100)))))

(define (alipay-parse-cny text)
  (unless (and (string? text)
               (regexp-match? #px"^(?:0|[1-9][0-9]{0,8})(?:[.][0-9]{1,2})?$" text))
    (reject 'alipay-amount-invalid "invalid Alipay decimal amount"))
  (let* ([parts (string-split text "." #:trim? #f)]
         [fen (+ (* 100 (string->number (car parts)))
                 (if (null? (cdr parts))
                     0
                     (string->number
                      (if (= (string-length (cadr parts)) 1)
                          (string-append (cadr parts) "0")
                          (cadr parts)))))])
    (unless (<= 1 fen max-cny-fen)
      (reject 'alipay-amount-invalid "Alipay amount outside approved bounds"))
    (money "CNY" fen)))

(define (hex-digit n)
  (cond [(<= 48 n 57) (- n 48)]
        [(<= 65 n 70) (- n 55)]
        [(<= 97 n 102) (- n 87)]
        [else #f]))

(define (decode-form-part raw)
  (define data
    (call-with-output-bytes
     (lambda (out)
       (let loop ([i 0])
         (when (< i (bytes-length raw))
           (define c (bytes-ref raw i))
           (cond
             [(= c 37)
              (when (>= (+ i 2) (bytes-length raw))
                (reject 'alipay-form-invalid "malformed percent escape"))
              (let ([high (hex-digit (bytes-ref raw (add1 i)))]
                    [low (hex-digit (bytes-ref raw (+ i 2)))])
                (unless (and high low)
                  (reject 'alipay-form-invalid "malformed percent escape"))
                (write-byte (+ (* high 16) low) out)
                (loop (+ i 3)))]
             [else
              (write-byte (if (= c 43) 32 c) out)
              (loop (add1 i))]))))))
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (reject 'alipay-form-invalid "invalid UTF-8 form value"))])
    (bytes->string/utf-8 data)))

(define (alipay-decode-form raw)
  (unless (bytes? raw)
    (reject 'alipay-form-invalid "Alipay notification requires raw bytes"))
  (unless (<= 1 (bytes-length raw) max-form-bytes)
    (reject 'alipay-form-invalid "Alipay notification exceeds size limit"))
  (let ([parts (regexp-split #rx#"&" raw)])
    (when (> (length parts) max-params)
      (reject 'alipay-form-invalid "too many Alipay form fields"))
    (for/fold ([params (hash)]) ([part (in-list parts)])
      (define pos
        (for/first ([i (in-range (bytes-length part))]
                    #:when (= 61 (bytes-ref part i)))
          i))
      (unless (and pos (> pos 0))
        (reject 'alipay-form-invalid "malformed Alipay form field"))
      (let* ([name (decode-form-part (subbytes part 0 pos))]
             [value (decode-form-part (subbytes part (add1 pos)))])
        (unless (regexp-match? #px"^[A-Za-z][A-Za-z0-9_]*$" name)
          (reject 'alipay-form-invalid "invalid Alipay field name"))
        (when (hash-has-key? params name)
          (reject 'alipay-form-invalid "duplicate Alipay form field"))
        (hash-set params name value)))))

(define (alipay-canonical-parameters params #:notification? [notification? #t])
  (unless (and (hash? params)
               (for/and ([(k v) (in-hash params)])
                 (and (string? k) (string? v))))
    (reject 'alipay-form-invalid "Alipay parameters must be strings"))
  ;; Alipay rsaCheckV1 uses decoded values, skips empty values, and excludes
  ;; sign/sign_type. Never re-encode, case-fold or normalize decoded values.
  (string-join
   (for/list ([name (in-list (sort (hash-keys params) string<?))]
              #:unless (or (string=? name "sign")
                           (and notification? (string=? name "sign_type"))
                           (string=? (hash-ref params name) "")))
     (string-append name "=" (hash-ref params name)))
   "&"))

(define (read-key pem label format)
  (unless (nonempty? pem)
    (reject 'alipay-key-invalid "Alipay RSA key not configured"))
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (reject 'alipay-key-invalid "invalid Alipay RSA key"))])
    (define entry
      (call-with-input-bytes
       (string->bytes/utf-8 pem)
       (lambda (in) (read-pem in #:only (list label)))))
    (unless entry
      (reject 'alipay-key-invalid "missing Alipay PEM key"))
    (datum->pk-key (cdr entry) format (list libcrypto-factory))))

(define (encode-base64 bytes)
  (bytes->string/utf-8 (base64-encode bytes #:line #f)))

(define (decode-base64 text)
  (unless (and (string? text)
               (regexp-match? #px"^[A-Za-z0-9+/]+={0,2}$" text)
               (zero? (modulo (string-length text) 4)))
    (reject 'alipay-signature-invalid "invalid Alipay signature"))
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (reject 'alipay-signature-invalid "invalid Alipay signature"))])
    (define bytes (base64-decode (string->bytes/utf-8 text)))
    (unless (string=? (encode-base64 bytes) text)
      (reject 'alipay-signature-invalid "noncanonical Alipay signature"))
    bytes))

(define (alipay-sign-parameters params merchant-private-key-pem)
  (define key (read-key merchant-private-key-pem #"PRIVATE KEY" 'PrivateKeyInfo))
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (reject 'alipay-signature-invalid "could not sign Alipay request"))])
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (encode-base64
       (digest/sign key 'sha256
                    (string->bytes/utf-8
                     (alipay-canonical-parameters params #:notification? #f))
                    #:pad 'pkcs1-v1.5)))))

(define (make-alipay-page-pay-parameters binding merchant-private-key-pem
                                         subject timestamp notify-url
                                         #:return-url [return-url #f])
  (unless (alipay-order-binding? binding)
    (reject 'alipay-binding-invalid "missing checkout binding"))
  (unless (and (nonempty? subject)
               (<= (string-length subject) 256)
               (not (regexp-match? #px"[&/=]" subject))
               (string? timestamp)
               (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"
                              timestamp)
               (string? notify-url)
               (string-prefix? notify-url "https://")
               (or (not return-url)
                   (and (string? return-url)
                        (string-prefix? return-url "https://"))))
    (reject 'alipay-checkout-invalid "invalid Alipay checkout parameters"))
  (let* ([business
          (jsexpr->string
           (hasheq 'out_trade_no (alipay-order-binding-out-trade-no binding)
                   'total_amount (alipay-cny->text
                                  (alipay-order-binding-amount binding))
                   'subject subject
                   'product_code "FAST_INSTANT_TRADE_PAY"))]
         [fields
          (hash "app_id" (alipay-order-binding-app-id binding)
                "method" "alipay.trade.page.pay"
                "format" "JSON"
                "charset" "utf-8"
                "sign_type" "RSA2"
                "timestamp" timestamp
                "version" "1.0"
                "notify_url" notify-url
                "biz_content" business)]
         [final (if return-url
                    (hash-set fields "return_url" return-url)
                    fields)])
    (hash-set final "sign"
              (alipay-sign-parameters final merchant-private-key-pem))))


;; Build an authenticated, bound active order query. The merchant service
;; submits these fields over HTTPS to the configured Alipay gateway; it must
;; keep request->response correlation and never let the buyer select the order.
(define (make-alipay-trade-query-parameters binding merchant-private-key-pem
                                            timestamp)
  (unless (alipay-order-binding? binding)
    (reject 'alipay-binding-invalid "missing checkout binding"))
  (unless (and (string? timestamp)
               (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"
                              timestamp))
    (reject 'alipay-query-invalid "invalid Alipay query timestamp"))
  (let ([fields
         (hash "app_id" (alipay-order-binding-app-id binding)
               "method" "alipay.trade.query"
               "format" "JSON"
               "charset" "utf-8"
               "sign_type" "RSA2"
               "timestamp" timestamp
               "version" "1.0"
               "biz_content"
               (jsexpr->string
                (hasheq 'out_trade_no
                        (alipay-order-binding-out-trade-no binding))))])
    (hash-set fields "sign"
              (alipay-sign-parameters fields merchant-private-key-pem))))

(define (required params name)
  (define value (hash-ref params name #f))
  (unless (nonempty? value)
    (reject 'alipay-notification-invalid "missing required Alipay field"))
  value)

(define (sha256-hex raw)
  (define digest-bytes
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest 'sha256 raw)))
  (apply string-append
         (for/list ([n (in-bytes digest-bytes)])
           (define text (number->string n 16))
           (if (= (string-length text) 1)
               (string-append "0" text)
               text))))

(define (verify-alipay-notification raw binding alipay-public-key-pem)
  (unless (alipay-order-binding? binding)
    (reject 'alipay-binding-invalid "missing checkout binding"))
  (let ([params (alipay-decode-form raw)])
    (unless (string=? (required params "sign_type") "RSA2")
      (reject 'alipay-signature-invalid "unsupported Alipay signature algorithm"))
    (let* ([signed-bytes
            (string->bytes/utf-8 (alipay-canonical-parameters params))]
           [signature (decode-base64 (required params "sign"))]
           [key (read-key alipay-public-key-pem #"PUBLIC KEY"
                          'SubjectPublicKeyInfo)]
           [valid?
            (with-handlers ([exn:fail? (lambda (_) #f)])
              (parameterize ([crypto-factories (list libcrypto-factory)])
                (digest/verify key 'sha256 signed-bytes signature
                               #:pad 'pkcs1-v1.5)))])
      (unless valid?
        (reject 'alipay-signature-invalid "invalid Alipay RSA2 signature"))
      ;; A signed callback alone is NOT enough to issue rights.
      (unless (and (string=? (required params "app_id")
                             (alipay-order-binding-app-id binding))
                   (string=? (required params "seller_id")
                             (alipay-order-binding-seller-id binding))
                   (string=? (required params "out_trade_no")
                             (alipay-order-binding-out-trade-no binding))
                   (equal? (alipay-parse-cny (required params "total_amount"))
                           (alipay-order-binding-amount binding)))
        (reject 'alipay-order-mismatch "Alipay order does not match checkout binding"))
      (unless (string=? (required params "notify_type") "trade_status_sync")
        (reject 'alipay-notification-invalid "unsupported Alipay notification type"))
      (when (and (hash-has-key? params "auth_app_id")
                 (not (string=? (required params "auth_app_id")
                                (alipay-order-binding-app-id binding))))
        (reject 'alipay-order-mismatch "Alipay authorized app mismatch"))
      ;; Refund and fund-distribution callbacks are not purchase events.
      ;; Never classify a TRADE_SUCCESS with refund metadata as a fresh sale.
      (when (or (hash-has-key? params "refund_fee")
                (hash-has-key? params "gmt_refund")
                (hash-has-key? params "out_biz_no"))
        (reject 'alipay-refund-unsupported
                "refund notification requires separate refund verification"))
      (let ([status (required params "trade_status")])
        (unless (member status '("TRADE_SUCCESS" "TRADE_FINISHED"))
          (reject 'alipay-not-paid "Alipay notification is not a completed payment"))
        (alipay-notification
         (required params "notify_id")
         (required params "trade_no")
         status
         (alipay-order-binding-out-trade-no binding)
         (alipay-order-binding-amount binding)
         (sha256-hex (bytes->immutable-bytes raw)))))))


;; The Alipay OpenAPI signature covers the RAW JSON value of
;; alipay_trade_query_response, not the reserialized parsed object.
;; This parser accepts only the documented simple key-mode wrapper with
;; one response and one signature. Certificate-mode envelopes require a
;; separately reviewed implementation and are refused rather than guessed.
(define (extract-signed-trade-response raw)
  (unless (and (bytes? raw)
               (<= 1 (bytes-length raw) max-form-bytes))
    (reject 'alipay-query-invalid "invalid signed Alipay query response size"))
  (define text
    (with-handlers ([exn:fail?
                     (lambda (_) (reject 'alipay-query-invalid
                                         "invalid query response encoding"))])
      (bytes->string/utf-8 raw)))
  (define prefix
    (regexp-match-positions
     #px"^\\s*\\{\\s*\"alipay_trade_query_response\"\\s*:\\s*" text))
  (unless prefix
    (reject 'alipay-query-invalid "unrecognized Alipay signed query envelope"))
  (let ([start (cdar prefix)])
    (unless (and (< start (string-length text))
                 (char=? (string-ref text start) #\{))
      (reject 'alipay-query-invalid "missing Alipay response body"))
    (define end
      (let loop ([i start] [depth 0] [quoted? #f] [escaped? #f])
        (when (>= i (string-length text))
          (reject 'alipay-query-invalid "unterminated Alipay JSON response"))
        (let ([ch (string-ref text i)])
          (cond
            [quoted?
             (cond
               [escaped? (loop (add1 i) depth #t #f)]
               [(char=? ch #\\) (loop (add1 i) depth #t #t)]
               [(char=? ch #\") (loop (add1 i) depth #f #f)]
               [else (loop (add1 i) depth #t #f)])]
            [(char=? ch #\") (loop (add1 i) depth #t #f)]
            [(char=? ch #\{) (loop (add1 i) (add1 depth) #f #f)]
            [(char=? ch #\})
             (if (= depth 1)
                 (add1 i)
                 (loop (add1 i) (sub1 depth) #f #f))]
            [else (loop (add1 i) depth #f #f)]))))
    (let* ([body (substring text start end)]
           [tail (substring text end)]
           [matches
            (regexp-match
             #px"^\\s*,\\s*\"sign\"\\s*:\\s*\"([A-Za-z0-9+/=]+)\"\\s*\\}\\s*$"
             tail)])
      (unless (and matches (= (length matches) 2))
        (reject 'alipay-query-invalid "invalid signed Alipay query trailer"))
      (values body (cadr matches)))))

(define (read-trade-response body)
  ;; A verified signature is necessary but not sufficient when member names
  ;; may be ambiguous. The five critical names must occur precisely once.
  ;; Nontrivial nested ambiguity is rejected, not silently last-wins parsed.
  (for ([name '("code" "trade_no" "out_trade_no"
                "trade_status" "total_amount")])
    (unless (= 1
               (length (regexp-match*
                        (regexp (string-append "\"" name "\"[ \t\r\n]*:"))
                        body)))
      (reject 'alipay-query-invalid "ambiguous signed query fields")))
  (define parsed
    (with-handlers ([exn:fail?
                     (lambda (_) (reject 'alipay-query-invalid
                                         "invalid signed Alipay JSON"))])
      (string->jsexpr body)))
  (unless (hash? parsed)
    (reject 'alipay-query-invalid "invalid signed Alipay query object"))
  parsed)

(define (query-field parsed field)
  (define value (hash-ref parsed field #f))
  (unless (nonempty? value)
    (reject 'alipay-query-invalid "missing Alipay query response field"))
  value)

(define (verified-alipay-trade-query->payment-event
         raw binding alipay-public-key-pem observed-at
         #:notification [notice #f])
  (unless (and (alipay-order-binding? binding)
               (exact-nonnegative-integer? observed-at)
               (or (not notice) (alipay-notification? notice)))
    (reject 'alipay-query-invalid "invalid signed trade query context"))
  (define-values (body signature-text)
    (extract-signed-trade-response raw))
  (define key
    (read-key alipay-public-key-pem #"PUBLIC KEY" 'SubjectPublicKeyInfo))
  (define signed?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (parameterize ([crypto-factories (list libcrypto-factory)])
        (digest/verify key 'sha256
                       (string->bytes/utf-8 body)
                       (decode-base64 signature-text)
                       #:pad 'pkcs1-v1.5))))
  (unless signed?
    (reject 'alipay-signature-invalid "invalid Alipay trade query signature"))
  (let* ([parsed (read-trade-response body)]
         [trade-no (query-field parsed 'trade_no)]
         [out-trade-no (query-field parsed 'out_trade_no)]
         [status (query-field parsed 'trade_status)]
         [amount (alipay-parse-cny (query-field parsed 'total_amount))])
    (unless (string=? (query-field parsed 'code) "10000")
      (reject 'alipay-query-invalid "Alipay query did not succeed"))
    (unless (and (string=? out-trade-no
                           (alipay-order-binding-out-trade-no binding))
                 (equal? amount (alipay-order-binding-amount binding))
                 (or (not notice)
                     (and (string=? trade-no
                                    (alipay-notification-trade-no notice))
                          (string=? out-trade-no
                                    (alipay-notification-order-id notice)))))
      (reject 'alipay-order-mismatch "Alipay trade lookup mismatch"))
    ;; Some contracts omit these in the query payload. If returned, refuse
    ;; cross-app or cross-seller contamination.
    (when (or (and (hash-has-key? parsed 'app_id)
                   (not (equal? (hash-ref parsed 'app_id)
                                (alipay-order-binding-app-id binding))))
              (and (hash-has-key? parsed 'seller_id)
                   (not (equal? (hash-ref parsed 'seller_id)
                                (alipay-order-binding-seller-id binding)))))
      (reject 'alipay-order-mismatch "Alipay query merchant identity mismatch"))
    (unless (member status '("TRADE_SUCCESS" "TRADE_FINISHED"))
      (reject 'alipay-not-paid "Alipay trade query is not paid"))
    ;; Partial refunds must not silently produce an unqualified first grant.
    ;; A dedicated authenticated refund/reconciliation path must handle them.
    (when (or (hash-has-key? parsed 'refund_fee)
              (hash-has-key? parsed 'gmt_refund))
      (reject 'alipay-refund-unsupported
              "trade query with refund state requires refund reconciliation"))
    (let ([digest-text (sha256-hex (bytes->immutable-bytes raw))])
      (make-verified-payment-event
       "alipay"
       (string-append "query-" digest-text)
       digest-text
       'payment-succeeded
       out-trade-no
       (alipay-order-binding-offer-id binding)
       (alipay-order-binding-subject-id binding)
       amount
       observed-at))))
