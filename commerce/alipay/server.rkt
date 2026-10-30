#lang racket/base

;; Explicit Alipay webhook edge. Only a signed notification plus an
;; independently verified trade.query response may enter Commerce's journal.
;; The actual Permit issuer remains a distinct outbox worker.
(provide
 make-alipay-webhook-endpoint
 alipay-webhook-endpoint?
 handle-alipay-webhook-post
 serve-alipay-webhook-endpoint)

(require file/sha1
         racket/date
         net/url
         web-server/http
         web-server/servlet-env
         "../alipay.rkt"
         "../journal.rkt"
         "../storage.rkt"
         "../private/model.rkt")

(struct alipay-webhook-endpoint
  (app-id seller-id public-key-pem query-order storage))

(define (make-alipay-webhook-endpoint
         #:app-id app-id
         #:seller-id seller-id
         #:alipay-public-key public-key-pem
         #:query-order query-order
         #:storage storage)
  (unless (and (string? app-id) (positive? (string-length app-id))
               (string? seller-id) (positive? (string-length seller-id))
               (string? public-key-pem) (positive? (string-length public-key-pem))
               (procedure? query-order) (commerce-storage? storage))
    (raise-arguments-error
     'make-alipay-webhook-endpoint
     "expected app id, seller id, Alipay public key, query callback and Commerce storage"))
  (alipay-webhook-endpoint app-id seller-id public-key-pem query-order storage))

(define (problem status message)
  (values status (string->bytes/utf-8 message)))

;; Alipay TRADE_SUCCESS carries a stable GMT+8 payment timestamp. Do NOT
;; replace it with server receipt time: a retry arriving after one second
;; must have identical canonical event fields or the journal would report
;; a false conflicting replay for the same notify_id.
(define (alipay-payment-epoch notification)
  (define found (assoc "gmt_payment" (alipay-notification-fields notification)))
  (define raw-time (and found (cdr found)))
  (define parts
    (and (string? raw-time)
         (regexp-match
          #px"^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$"
          raw-time)))
  (unless parts
    (problem/error 'alipay-order-mismatch))
  (define nums (map string->number (cdr parts)))
  (define-values (year month day hour minute second)
    (apply values nums))
  (unless (and (<= 2000 year 2100) (<= 1 month 12)
               (<= 1 day 31) (<= 0 hour 23)
               (<= 0 minute 59) (<= 0 second 59))
    (problem/error 'alipay-order-mismatch))
  (define instant
    (with-handlers ([exn:fail? (lambda (_) (problem/error 'alipay-order-mismatch))])
      (find-seconds second minute hour day month year #f)))
  (define roundtrip (seconds->date instant #f))
  (unless (and (= (date-year roundtrip) year)
               (= (date-month roundtrip) month)
               (= (date-day roundtrip) day)
               (= (date-hour roundtrip) hour)
               (= (date-minute roundtrip) minute)
               (= (date-second roundtrip) second))
    (problem/error 'alipay-order-mismatch))
  (- instant (* 8 60 60)))

(define (handle-alipay-webhook-post endpoint raw)
  (unless (alipay-webhook-endpoint? endpoint)
    (raise-argument-error 'handle-alipay-webhook-post
                          "alipay-webhook-endpoint?" endpoint))
  (unless (bytes? raw)
    (raise-argument-error 'handle-alipay-webhook-post "bytes?" raw))
  (with-handlers
      ([exn:fail:commerce?
        (lambda (err)
          (define code (exn:fail:commerce-code err))
          (cond
            [(memq code
                   '(alipay-form-invalid alipay-signature-invalid
                     alipay-fields-invalid alipay-public-key-invalid
                     alipay-duplicate-field alipay-amount-invalid))
             (problem 401 "failure")]
            [(eq? code 'event-conflict) (problem 409 "failure")]
            [(eq? code 'alipay-order-mismatch) (problem 422 "failure")]
            [else (problem 503 "failure")]))]
       [exn:fail? (lambda (_) (problem 503 "failure"))])
    (define fields (parse-alipay-form raw))
    (define notification
      (verify-alipay-notification
       fields (alipay-webhook-endpoint-public-key-pem endpoint)))
    (define order-id (alipay-notification-order-id notification))
    (define storage (alipay-webhook-endpoint-storage endpoint))
    (define stored (storage-checkout-binding-ref storage order-id))
    (unless (and stored
                 (equal? (checkout-binding-provider stored) "alipay")
                 (equal? (checkout-binding-merchant-external-id stored) order-id)
                 (equal? (checkout-binding-currency stored) "CNY")
                 (= (checkout-binding-currency-exponent stored) 2))
      (problem/error 'alipay-order-mismatch))
    (define binding
      (alipay-binding
       (alipay-webhook-endpoint-app-id endpoint)
       (alipay-webhook-endpoint-seller-id endpoint)
       order-id
       (checkout-binding-offer-id stored)
       (checkout-binding-subject-id stored)
       (money "CNY" (checkout-binding-amount-minor-units stored))))
    (define query-raw
      ((alipay-webhook-endpoint-query-order endpoint) binding))
    (define confirmed
      (verify-alipay-trade-query-response
       query-raw
       (alipay-webhook-endpoint-public-key-pem endpoint)
       binding))
    (define event
      (confirm-alipay-onetime-payment
       notification binding confirmed
       #:payload-digest (bytes->hex-string (sha256-bytes raw))
       #:occurred-at (alipay-payment-epoch notification)))
    ;; The only success acknowledgement follows a durable journal commit.
    ;; A replay is accepted idempotently by Commerce journal semantics.
    (journal-accept! storage raw event #:received-at (current-seconds))
    (problem 200 "success")))

(define (problem/error code)
  (raise (exn:fail:commerce "Alipay order binding mismatch"
                            (current-continuation-marks) code (hash))))

;; This explicit listener does not alter the existing Pancake HTTP edge. In
;; production place it behind an HTTPS reverse proxy with request-body and
;; rate limits; the servlet should not be exposed on a public plain HTTP IP.
(define (serve-alipay-webhook-endpoint endpoint
                                       #:port port
                                       #:listen-ip [listen-ip "127.0.0.1"])
  (define custodian (make-custodian))
  (parameterize ([current-custodian custodian])
    (serve/servlet
     (lambda (request)
       (define route (url->string (request-uri request)))
       (define-values (status response-body)
         (cond
           [(not (regexp-match? #rx"^/webhooks/alipay$" route))
            (problem 404 "not found")]
           [(not (equal? (request-method request) #"post"))
            (problem 405 "method not allowed")]
           [else
            (let ([content-type
                   (headers-assq* #"content-type" (request-headers/raw request))])
              (if (and content-type
                       (regexp-match?
                        #px#"^application/x-www-form-urlencoded(?:;|$)"
                        (header-value content-type)))
                  (handle-alipay-webhook-post
                   endpoint (or (request-post-data/raw request) #""))
                  (problem 415 "unsupported media type")))]))
       (response/full
        status
        #"Commerce"
        (current-seconds)
        #"text/plain; charset=utf-8"
        '()
        (list response-body)))
     #:port port
     #:listen-ip listen-ip
     #:command-line? #f
     #:servlet-path "/webhooks/alipay"
     #:servlet-regexp #rx"^/webhooks/alipay$"))
  (lambda () (custodian-shutdown-all custodian)))
