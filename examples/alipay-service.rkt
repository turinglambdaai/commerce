#lang racket/base

;; Example edge process for an already approved Alipay merchant account.
;; Behind a TLS reverse proxy, this process listens only on loopback.
;; Never co-locate a Permit issuer private key in this HTTP process.
(require crypto
         crypto/libcrypto
         crypto/pem
         racket/file
         racket/port
         racket/string
         commerce/alipay
         commerce/alipay/client
         commerce/alipay/server
         commerce/storage
         commerce/storage/sqlite)

(define (required name)
  (define value (getenv name))
  (unless (and value (not (string=? value "")))
    (error 'alipay-service "missing required environment setting: ~a" name))
  value)

(define (read-key path)
  (define pem (file->string path))
  (define entry
    (call-with-input-string
     (string-replace pem "\r\n" "\n")
     (lambda (in)
       (read-pem in #:only (list #"PRIVATE KEY" #"RSA PRIVATE KEY")))))
  (unless (and (pair? entry)
               (member (car entry) (list #"PRIVATE KEY" #"RSA PRIVATE KEY")))
    (error 'alipay-service "merchant private key is not a supported RSA PEM"))
  (define format
    (if (bytes=? (car entry) #"PRIVATE KEY")
        'OneAsymmetricKey 'RSAPrivateKey))
  (define key (datum->pk-key (cdr entry) format (list libcrypto-factory)))
  (unless (private-key? key)
    (error 'alipay-service "merchant RSA key is invalid"))
  key)

(module+ main
  (define environment
    (case (string->symbol (required "ALIPAY_ENV"))
      [(sandbox) 'sandbox]
      [(production) 'production]
      [else (error 'alipay-service "ALIPAY_ENV must be sandbox or production")]))
  (define app-id (required "ALIPAY_APP_ID"))
  (define seller-id (required "ALIPAY_SELLER_ID"))
  (define private-key (read-key (required "ALIPAY_PRIVATE_KEY_PATH")))
  (define alipay-public-key
    (file->string (required "ALIPAY_PUBLIC_KEY_PATH")))
  (define port (string->number (required "COMMERCE_HTTP_PORT")))
  (unless (and (exact-integer? port) (<= 1024 port 65535))
    (error 'alipay-service "COMMERCE_HTTP_PORT must be between 1024 and 65535"))
  (define storage
    (open-sqlite-commerce-storage
     (required "COMMERCE_DATABASE_PATH")))
  (define client
    (make-alipay-query-client
     #:app-id app-id
     #:merchant-private-key private-key
     #:alipay-public-key alipay-public-key
     #:environment environment))
  (define edge
    (make-alipay-webhook-endpoint
     #:app-id app-id
     #:seller-id seller-id
     #:alipay-public-key alipay-public-key
     #:query-order
     (lambda (binding)
       (fetch-alipay-trade-query-response client binding))
     #:storage storage))
  (define stop
    (serve-alipay-webhook-endpoint
     edge #:port port #:listen-ip "127.0.0.1"))
  (displayln "Alipay callback edge listening on loopback; configure HTTPS proxy")
  (dynamic-wind
   void
   (lambda () (sync never-evt))
   (lambda ()
     (stop)
     (storage-close storage))))
