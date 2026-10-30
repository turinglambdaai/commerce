#lang racket/base

;; Alipay Vibe Pay Basic Collection (RSA2 public-key mode). No merchant API
;; credentials, HTTP client, or private keys are loaded by this module.
;; `return_url` is never payment evidence. A caller must actively query the
;; merchant order before supplying matching verified order facts.
(provide
 alipay-signing-content
 alipay-cny->fen
 (struct-out alipay-binding)
 (struct-out alipay-confirmed-order)
 (struct-out alipay-notification)
 verify-alipay-notification
 confirm-alipay-onetime-payment)

(require base64
         crypto
         crypto/libcrypto
         crypto/pem
         racket/list
         racket/string
         (only-in "provider.rkt" make-verified-payment-event)
         "private/model.rkt")

(define (fail code message)
  (raise (exn:fail:commerce message (current-continuation-marks) code (hash))))

(define (nonblank? s)
  (and (string? s) (positive? (string-length s))
       (not (regexp-match? #px"[\r\n]" s))))
(define (valid-fields? fields)
  (and (list? fields)
       (andmap (lambda (p)
                 (and (pair? p) (string? (car p))
                      (nonblank? (car p)) (string? (cdr p))))
               fields)))
(define (field fields name)
  (define x (assoc name fields))
  (and x (cdr x)))
(define (nonblank-field fields name)
  (define x (field fields name))
  (unless (nonblank? x) (fail 'alipay-fields-invalid "missing Alipay field"))
  x)

;; Input is a decoded, one-value-per-field association list. HTTP boundary
;; must use a parser preserving duplicated keys; never collapse to a hash.
;; The original values MUST retain their decoded spelling (no trimming).
(define (checked-fields who fields)
  (unless (valid-fields? fields)
    (raise-argument-error who "(listof (cons/c string? string?))" fields))
  (define names (map car fields))
  (unless (= (length names) (length (remove-duplicates names)))
    (fail 'alipay-duplicate-field "duplicate Alipay notification field"))
  fields)

(define (alipay-signing-content fields)
  (checked-fields 'alipay-signing-content fields)
  (string-join
   (for/list ([p (in-list (sort fields string<? #:key car))]
              #:unless (member (car p) '("sign" "sign_type")))
     (string-append (car p) "=" (cdr p)))
   "&"))

(define (alipay-cny->fen str)
  (unless (and (string? str)
               (regexp-match? #px"^(?:0|[1-9][0-9]*)(?:\\.[0-9]{1,2})?$" str))
    (fail 'alipay-amount-invalid "invalid CNY decimal amount"))
  (define parts (string-split str "."))
  (define whole (string->number (car parts)))
  (define fraction (if (null? (cdr parts)) "" (cadr parts)))
  (+ (* 100 whole)
     (string->number (substring (string-append fraction "00") 0 2))))

;; Binding is created from durable Commerce checkout state, never from
;; buyer_id / email / notify metadata.
(struct alipay-binding (app-id seller-id order-id offer-id subject-id amount)
  #:transparent
  #:guard (lambda (app seller order offer subject amount who)
            (unless (and (nonblank? app) (nonblank? seller)
                         (nonblank? order) (stable-id? offer)
                         (nonblank? subject) (money? amount)
                         (equal? (money-currency amount) "CNY"))
              (raise-arguments-error who "invalid server-side Alipay binding"))
            (values app seller order offer subject amount)))

;; This value must be constructed by the caller ONLY from an authenticated
;; active alipay.trade.query result. It must not be built from browser data.
(struct alipay-confirmed-order (app-id seller-id order-id trade-id status amount)
  #:transparent)
(struct alipay-notification (fields order-id trade-id status amount)
  #:transparent)

(define (read-public pem)
  (with-handlers ([exn:fail?
                   (lambda (_) (fail 'alipay-public-key-invalid
                                     "invalid Alipay public key"))])
    (define entry
      (call-with-input-bytes (string->bytes/utf-8 pem)
        (lambda (in) (read-pem in #:only (list #"PUBLIC KEY")))))
    (unless entry (error 'read-public "missing key"))
    (datum->pk-key (cdr entry) 'SubjectPublicKeyInfo
                   (list libcrypto-factory))))

(define (verify-alipay-notification fields public-key-pem)
  (checked-fields 'verify-alipay-notification fields)
  (unless (and (nonblank? public-key-pem)
               (equal? (field fields "sign_type") "RSA2"))
    (fail 'alipay-signature-invalid "invalid Alipay RSA2 signature mode"))
  (define signature
    (with-handlers ([exn:fail?
                     (lambda (_) (fail 'alipay-signature-invalid
                                       "invalid Alipay RSA2 signature"))])
      (base64-decode
       (string->bytes/utf-8 (nonblank-field fields "sign")))))
  (define signed-content
    (string->bytes/utf-8 (alipay-signing-content fields)))
  (define valid?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (digest/verify (read-public public-key-pem) 'sha256
                     signed-content signature #:pad 'pkcs1-v1.5)))
  (unless valid?
    (fail 'alipay-signature-invalid "invalid Alipay RSA2 signature"))
  (define amount (alipay-cny->fen (nonblank-field fields "total_amount")))
  (alipay-notification
   fields
   (nonblank-field fields "out_trade_no")
   (nonblank-field fields "trade_no")
   (nonblank-field fields "trade_status")
   amount))

;; The active query must be checked against the *same* persisted binding,
;; not trusted from an arbitrary service callback. This first slice handles
;; only full one-time payments; partial refund events need a separate model.
(define (confirm-alipay-onetime-payment notice binding query
                                        #:payload-digest payload-digest
                                        #:occurred-at occurred-at)
  (unless (and (alipay-notification? notice)
               (alipay-binding? binding)
               (alipay-confirmed-order? query))
    (raise-arguments-error 'confirm-alipay-onetime-payment
                           "expected signed notification, binding and active query"))
  (define f (alipay-notification-fields notice))
  (unless (and
           (equal? (alipay-notification-status notice) "TRADE_SUCCESS")
           (equal? (alipay-confirmed-order-status query) "TRADE_SUCCESS")
           (equal? (nonblank-field f "app_id") (alipay-binding-app-id binding))
           (equal? (nonblank-field f "seller_id") (alipay-binding-seller-id binding))
           (equal? (alipay-notification-order-id notice) (alipay-binding-order-id binding))
           (equal? (alipay-notification-trade-id notice) (alipay-confirmed-order-trade-id query))
           (= (alipay-notification-amount notice)
              (money-minor-units (alipay-binding-amount binding)))
           (equal? (alipay-confirmed-order-app-id query) (alipay-binding-app-id binding))
           (equal? (alipay-confirmed-order-seller-id query) (alipay-binding-seller-id binding))
           (equal? (alipay-confirmed-order-order-id query) (alipay-binding-order-id binding))
           (= (alipay-confirmed-order-amount query)
              (money-minor-units (alipay-binding-amount binding))))
    (fail 'alipay-order-mismatch
          "Alipay notification and active order do not match checkout binding"))
  (make-verified-payment-event
   "alipay" (nonblank-field f "notify_id") payload-digest
   'payment-succeeded (alipay-binding-order-id binding)
   (alipay-binding-offer-id binding) (alipay-binding-subject-id binding)
   (alipay-binding-amount binding) occurred-at))
