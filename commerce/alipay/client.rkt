#lang racket/base

;; Merchant-only HTTPS query and journal boundary for Alipay Basic Collection.
;; The browser and application must never get merchant signing keys.
(provide make-alipay-merchant-client
         alipay-merchant-client?
         alipay-query-payment
         alipay-query-and-journal!)

(require net/http-easy
         racket/list
         racket/port
         racket/string
         "../alipay.rkt"
         "../journal.rkt"
         "../private/model.rkt")

(define sandbox-gateway "https://openapi.alipaydev.com/gateway.do")
(define max-query-response-bytes 65536)
(define hex-chars "0123456789ABCDEF")

(define (reject code message)
  (raise (exn:fail:commerce message (current-continuation-marks)
                            code (hash))))

;; A client struct intentionally has NO transparent inspector or key getters.
(struct alipay-merchant-client
  (environment private-key public-key connect-timeout request-timeout
               transport))

(define (default-query-transport endpoint headers body connect-timeout
                                 request-timeout)
  (define response
    (post endpoint
          #:headers headers
          #:data body
          #:timeouts (make-timeout-config #:connect connect-timeout
                                          #:request request-timeout)
          #:max-attempts 1
          #:max-redirects 0
          #:stream? #t))
  (dynamic-wind
    void
    (lambda ()
      (let ([body
             (sync/timeout request-timeout
                           (read-bytes-evt
                            (add1 max-query-response-bytes)
                            (response-output response)))])
        (unless body
          (reject 'alipay-query-unavailable "Alipay query read timed out"))
        (let ([data (if (eof-object? body) #"" body)])
          (when (> (bytes-length data) max-query-response-bytes)
            (reject 'alipay-query-invalid "Alipay query exceeded response limit"))
          (values (response-status-code response) data))))
    (lambda () (response-close! response))))

(define (make-alipay-merchant-client private-key-pem public-key-pem
                                    #:environment [environment 'sandbox]
                                    #:connect-timeout [connect-timeout 5]
                                    #:request-timeout [request-timeout 10]
                                    #:transport [transport default-query-transport])
  (unless (and (memq environment '(sandbox production))
               (string? private-key-pem)
               (positive? (string-length private-key-pem))
               (string? public-key-pem)
               (positive? (string-length public-key-pem))
               (positive-real? connect-timeout)
               (positive-real? request-timeout)
               (procedure? transport))
    (reject 'alipay-merchant-config-invalid "invalid Alipay merchant configuration"))
  (alipay-merchant-client environment private-key-pem public-key-pem
                          connect-timeout request-timeout transport))

(define (form-escape s)
  (apply string-append
         (for/list ([b (in-bytes (string->bytes/utf-8 s))])
           (let ([c (integer->char b)])
             (if (regexp-match? #px"^[A-Za-z0-9_.~-]$" (string c))
                 (string c)
                 (string #\%
                         (string-ref hex-chars (quotient b 16))
                         (string-ref hex-chars (remainder b 16))))))))

(define (form-encode params)
  (string->bytes/utf-8
   (string-join
    (for/list ([key (in-list (sort (hash-keys params) string<?))])
      (string-append (form-escape key) "="
                     (form-escape (hash-ref params key))))
    "&")))

(define (alipay-query-payment client binding timestamp observed-at
                              #:notification [notice #f])
  (unless (and (alipay-merchant-client? client)
               (alipay-order-binding? binding)
               (exact-nonnegative-integer? observed-at)
               (or (not notice) (alipay-notification? notice)))
    (reject 'alipay-query-invalid "invalid Alipay active query context"))
  (define fields
    (make-alipay-trade-query-parameters
     binding
     (alipay-merchant-client-private-key client)
     timestamp))
  (define endpoint
    (if (eq? (alipay-merchant-client-environment client) 'production)
        alipay-gateway-url
        sandbox-gateway))
  (define-values (status raw)
    (with-handlers ([exn:fail:commerce? raise]
                    [exn:fail?
                     (lambda (_)
                       (reject 'alipay-query-unavailable
                               "Alipay query transport is unavailable"))])
      ((alipay-merchant-client-transport client)
       endpoint
       (hash 'content-type "application/x-www-form-urlencoded; charset=utf-8")
       (form-encode fields)
       (alipay-merchant-client-connect-timeout client)
       (alipay-merchant-client-request-timeout client))))
  (unless (and (exact-integer? status) (bytes? raw)
               (<= (bytes-length raw) max-query-response-bytes))
    (reject 'alipay-query-invalid "malformed Alipay query HTTP response"))
  (cond
    [(or (= status 408) (= status 429) (<= 500 status 599))
     (reject 'alipay-query-unavailable "Alipay active query retryable failure")]
    [(not (= status 200))
     (reject 'alipay-query-invalid "Alipay active query rejected")])
  (let ([event
         (verified-alipay-trade-query->payment-event
          raw binding (alipay-merchant-client-public-key client)
          observed-at #:notification notice)])
    (values (bytes->immutable-bytes raw) event)))

(define (alipay-query-and-journal! storage client binding timestamp observed-at
                                   #:notification [notice #f])
  ;; Signer/issuer/outbox processing happens independently after the durable
  ;; journal transaction. A redirect or a signed callback never gets acked
  ;; as paid here without querying the authenticated merchant API.
  (let-values ([(raw event)
                (alipay-query-payment
                 client binding timestamp observed-at #:notification notice)])
    (journal-accept! storage raw event #:received-at observed-at)))
