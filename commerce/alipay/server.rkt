#lang racket/base

;; Standalone Alipay notify_url endpoint. It never accepts redirect proof,
;; buyer ids, or a signed callback as product authorization. The only
;; acknowledgement path is: stored binding -> RSA2 notice -> signed active
;; query -> committed Commerce journal. Issuance stays in the outbox worker.
(provide make-alipay-webhook-endpoint
         alipay-webhook-endpoint?
         handle-alipay-webhook-post
         serve-alipay-webhook-endpoint)

(require net/url
         racket/date
         web-server/http
         web-server/servlet-env
         "../alipay.rkt"
         "client.rkt"
         "../journal.rkt"
         "../storage.rkt"
         "../private/model.rkt")

(struct alipay-webhook-endpoint
  (merchant-client app-id seller-id storage))

(define (make-alipay-webhook-endpoint merchant-client app-id seller-id storage)
  (unless (and (alipay-merchant-client? merchant-client)
               (string? app-id)
               (positive? (string-length app-id))
               (string? seller-id)
               (positive? (string-length seller-id))
               (commerce-storage? storage))
    (raise
     (exn:fail:commerce
      "invalid Alipay webhook endpoint configuration"
      (current-continuation-marks)
      'alipay-merchant-config-invalid
      (hash))))
  (alipay-webhook-endpoint merchant-client app-id seller-id storage))

(define (handle-alipay-webhook-post endpoint raw
                                   #:timestamp timestamp
                                   #:observed-at observed-at)
  (unless (and (alipay-webhook-endpoint? endpoint)
               (bytes? raw)
               (string? timestamp)
               (exact-nonnegative-integer? observed-at))
    (raise-argument-error
     'handle-alipay-webhook-post
     "Alipay endpoint, raw bytes, string timestamp and epoch seconds"
     'invalid-context))
  (with-handlers ([exn:fail? (lambda (_) (values 200 #"fail"))])
    (let* ([params (alipay-decode-form raw)]
           [out-trade-no (hash-ref params "out_trade_no" #f)])
      (unless (and (string? out-trade-no)
                   (positive? (string-length out-trade-no)))
        (error 'handle-alipay-webhook-post "missing order identity"))
      (let ([record
             (storage-checkout-binding-ref
              (alipay-webhook-endpoint-storage endpoint) out-trade-no)])
        (unless (and record
                     (checkout-binding? record)
                     (string=? (checkout-binding-provider record) "alipay")
                     (string=? (checkout-binding-currency record) "CNY")
                     (= (checkout-binding-currency-exponent record) 2))
          (error 'handle-alipay-webhook-post "missing server-side Alipay binding"))
        (let* ([binding
                (make-alipay-order-binding
                 out-trade-no
                 (checkout-binding-offer-id record)
                 (checkout-binding-subject-id record)
                 (money "CNY" (checkout-binding-amount-minor-units record))
                 (alipay-webhook-endpoint-app-id endpoint)
                 (alipay-webhook-endpoint-seller-id endpoint))]
               [notice
                (alipay-client-verify-notification
                 (alipay-webhook-endpoint-merchant-client endpoint)
                 raw binding)]
               [acceptance
                (alipay-query-and-journal!
                 (alipay-webhook-endpoint-storage endpoint)
                 (alipay-webhook-endpoint-merchant-client endpoint)
                 binding timestamp observed-at #:notification notice)])
          (values
           200
           (if (memq (journal-acceptance-disposition acceptance)
                     '(accepted replayed))
               #"success"
               #"fail")))))))

(define (local-trade-timestamp [epoch (current-seconds)])
  ;; Alipay requires wall-clock GMT+8, independent of the host TZ / DST.
  ;; Shift the UTC epoch and render as UTC to avoid double timezone offsets.
  (define d (seconds->date (+ epoch (* 8 60 60)) #f))
  (define (two n)
    (if (< n 10) (string-append "0" (number->string n))
        (number->string n)))
  (string-append
   (number->string (date-year d)) "-"
   (two (date-month d)) "-"
   (two (date-day d)) " "
   (two (date-hour d)) ":"
   (two (date-minute d)) ":"
   (two (date-second d))))

(define (serve-alipay-webhook-endpoint endpoint
                                      #:port port
                                      #:listen-ip [listen-ip "127.0.0.1"])
  (define custodian (make-custodian))
  (parameterize ([current-custodian custodian])
    (serve/servlet
     (lambda (request)
       (define path (url->string (request-uri request)))
       (define-values (status body)
         (if (and (regexp-match? #rx"^/webhooks/alipay$" path)
                  (bytes=? (request-method request) #"POST"))
             (handle-alipay-webhook-post
              endpoint (or (request-post-data/raw request) #"")
              #:timestamp (local-trade-timestamp)
              #:observed-at (current-seconds))
             (values 404 #"fail")))
       (response/full
        status #"commerce-alipay-endpoint" (current-seconds)
        #"text/plain; charset=utf-8" '() (list body)))
     #:port port
     #:listen-ip listen-ip
     #:command-line? #f
     #:servlet-path "/webhooks/alipay"
     #:servlet-regexp #rx"^/webhooks/alipay$"))
  (lambda () (custodian-shutdown-all custodian)))

(module+ test
  (require rackunit)
  (test-case "Alipay request timestamp uses GMT+8 on any host"
    (check-equal? (local-trade-timestamp 0) "1970-01-01 08:00:00")
    (check-equal? (local-trade-timestamp 57900) "1970-01-02 00:05:00")))
