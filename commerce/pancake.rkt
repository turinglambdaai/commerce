#lang racket/base

(provide
 pancake-webhook-keyring
 pancake-webhook-keyring?
 default-pancake-webhook-keyring
 pancake-webhook?
 pancake-webhook-environment
 pancake-webhook-id
 pancake-webhook-timestamp
 pancake-webhook-event-type
 pancake-webhook-event-id
 pancake-webhook-store-id
 pancake-webhook-store-name
 pancake-webhook-data
 pancake-webhook-raw-body
 pancake-webhook-payload-digest
 pancake-webhook-signature-timestamp-ms
 verify-pancake-webhook)

(require base64
         crypto
         crypto/libcrypto
         crypto/pem
         json
         racket/list
         racket/match
         racket/port
         racket/string
         "private/model.rkt")

(define default-past-tolerance-ms (* 45 60 1000))
(define default-future-tolerance-ms (* 60 1000))

;; These environment-specific verification keys mirror Pancake's official Go
;; SDK v0.17.0 (2026-10-10). Keeping them in a keyring makes the trust boundary
;; explicit and gives callers a controlled override for provider key rotation.
(define builtin-test-public-key
  #<<PEM
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxnmRY6yMMA3lVqmAU6ZG
b1sjL/+r/z6E+ZjkXaDAKiqOhk9rpazni0bNsGXwmftTPk9jy2wn+j6JHODD/WH/
SCnSfvKkLIjy4Hk7BuCgB174C0ydan7J+KgXLkOwgCAxxB68t2tezldwo74ZpXgn
F49opzMvQ9prEwIAWOE+kV9iK6gx/AckSMtHIHpUesoPDkldpmFHlB2qpf1vsFTZ
5kD6DmGl+2GIVK01aChy2lk8pLv0yUMu18v44sLkO5M44TkGPJD9qG09wrvVG2wp
OTVCn1n5pP8P+HRLcgzbUB3OlZVfdFurn6EZwtyL4ZD9kdkQ4EZE/9inKcp3c1h4
xwIDAQAB
-----END PUBLIC KEY-----
PEM
  )

(define builtin-production-public-key
  #<<PEM
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAz+xApdTIb4ua+DgZKQ54
iBsD82ybyhGCLRETONW4Jgbb3A8DUM1LqBk6r/CmTOCHqLalTQHNigvP3R5zkDNX
iRJz6gA4MJ/+8K0+mnEE2RISQzN+Qu65TNd6svb+INm/kMaftY4uIXr6y6kchtTJ
dwnQhcKdAL2v7h7IFnkVelQsKxDdb2PqX8xX/qwd01iXvMcpCCaXovUwZsxH2QN5
ZKBTseJivbhUeyJCco4fdUyxOMHe2ybCVhyvim2uxAl1nkvL5L8RCWMCAV55LLo0
9OhmLahz/DYNu13YLVP6dvIT09ZFBYU6Owj1NxdinTynlJCFS9VYwBgmftosSE1U
dwIDAQAB
-----END PUBLIC KEY-----
PEM
  )

(define (non-empty-string? value)
  (and (string? value) (not (string=? (string-trim value) ""))))

(define (same-pem-text? left right)
  (string=? (regexp-replace* #px"\\s+" left "")
            (regexp-replace* #px"\\s+" right "")))

(struct pancake-webhook-keyring (test-key production-key)
  #:guard
  (lambda (test-key production-key who)
    (unless (non-empty-string? test-key)
      (raise-arguments-error
       who "test public key must be a non-empty string"))
    (unless (non-empty-string? production-key)
      (raise-arguments-error
       who "production public key must be a non-empty string"))
    (when (same-pem-text? test-key production-key)
      (raise-arguments-error
       who "test and production public keys must be different"))
    (values test-key production-key)))

(define default-pancake-webhook-keyring
  (pancake-webhook-keyring
   builtin-test-public-key
   builtin-production-public-key))

;; The verified value deliberately remains provider-native. A later adapter
;; slice may query the active order and construct a canonical payment-event.
(struct pancake-webhook
  (environment id timestamp event-type event-id store-id store-name data
               raw-body payload-digest signature-timestamp-ms))

(define (raise-commerce code message [data (hash)])
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (environment? value)
  (memq value '(test production)))

(define (parse-signature-header header)
  (unless (string? header)
    (raise-arguments-error
     'verify-pancake-webhook
     "signature-header must be a string"))
  (when (string=? header "")
    (raise-commerce
     'pancake-signature-header-missing
     "missing X-Waffo-Signature header"))
  (define fields
    (for/fold ([parsed (hash)]) ([part (in-list (string-split header ","))])
      (match (regexp-match #px"^([^=]+)=(.*)$" part)
        [(list _ raw-name raw-value)
         (define name (string-trim raw-name))
         (define value (string-trim raw-value))
         (cond
           [(member name '("t" "v1"))
            (when (or (string=? value "") (hash-has-key? parsed name))
              (raise-commerce
               'pancake-signature-header-malformed
               "malformed X-Waffo-Signature header"))
            (hash-set parsed name value)]
           [else parsed])]
        [_ parsed])))
  (unless (and (hash-has-key? fields "t")
               (hash-has-key? fields "v1"))
    (raise-commerce
     'pancake-signature-header-malformed
     "malformed X-Waffo-Signature header"))
  (values (hash-ref fields "t") (hash-ref fields "v1")))

(define (parse-timestamp value)
  (unless (regexp-match? #px"^(?:0|[1-9][0-9]*)$" value)
    (raise-commerce
     'pancake-timestamp-invalid
     "invalid timestamp in X-Waffo-Signature header"))
  (define timestamp (string->number value))
  (unless (exact-nonnegative-integer? timestamp)
    (raise-commerce
     'pancake-timestamp-invalid
     "invalid timestamp in X-Waffo-Signature header"))
  timestamp)

(define (check-timestamp-window timestamp now-ms past-tolerance-ms
                                future-tolerance-ms)
  (define age (- now-ms timestamp))
  (when (or (> age past-tolerance-ms)
            (< age (- future-tolerance-ms)))
    (raise-commerce
     'pancake-timestamp-outside-tolerance
     "webhook timestamp is outside the accepted tolerance window"
     (hash 'past-tolerance-ms past-tolerance-ms
           'future-tolerance-ms future-tolerance-ms))))

(define (public-key-for keyring environment)
  (case environment
    [(test) (pancake-webhook-keyring-test-key keyring)]
    [(production) (pancake-webhook-keyring-production-key keyring)]))

(define (parse-public-key pem environment)
  (with-handlers ([exn:fail?
                   (lambda (_failure)
                     (raise-commerce
                      'pancake-public-key-invalid
                      "Pancake webhook public key is invalid"
                      (hash 'environment environment)))])
    (define entry
      (call-with-input-bytes
       (string->bytes/utf-8 pem)
       (lambda (in)
         (read-pem in #:only (list #"PUBLIC KEY")))))
    (unless entry
      (error 'parse-public-key "no PUBLIC KEY entry"))
    (datum->pk-key
     (cdr entry)
     'SubjectPublicKeyInfo
     (list libcrypto-factory))))

(define (decode-signature encoded environment)
  (with-handlers ([exn:fail?
                   (lambda (_failure)
                     (raise-commerce
                      'pancake-signature-invalid
                      "invalid Pancake webhook signature"
                      (hash 'environment environment)))])
    (base64-decode (string->bytes/utf-8 encoded))))

(define (verify-signature public-key signed-bytes signature environment)
  (define valid?
    (with-handlers ([exn:fail? (lambda (_failure) #f)])
      (digest/verify
       public-key 'sha256 signed-bytes signature #:pad 'pkcs1-v1.5)))
  (unless valid?
    (raise-commerce
     'pancake-signature-invalid
     "invalid Pancake webhook signature"
     (hash 'environment environment))))

(define (payload-digest raw-body)
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (bytes->hex-string (digest 'sha256 raw-body))))

(define required-string-fields
  '(id timestamp eventType eventId storeId storeName))

(define (duplicate-top-level-key raw-body)
  ;; Racket's JSON reader intentionally keeps the last value of a duplicate
  ;; object key. Inspect the authenticated representation first so security-
  ;; critical envelope fields cannot be interpreted differently elsewhere.
  (define stack '())
  (define in-string? #f)
  (define escaped? #f)
  (define key-start #f)
  (define expect-key? #f)
  (define seen (hash))
  (define duplicate #f)
  (for ([index (in-range (bytes-length raw-body))]
        #:break duplicate)
    (define byte (bytes-ref raw-body index))
    (cond
      [in-string?
       (cond
         [escaped? (set! escaped? #f)]
         [(= byte 92) (set! escaped? #t)] ; backslash
         [(= byte 34)                    ; double quote
          (set! in-string? #f)
          (when key-start
            (define key
              (with-handlers ([exn:fail? (lambda (_failure) #f)])
                (bytes->jsexpr (subbytes raw-body key-start (add1 index)))))
            (when (string? key)
              (if (hash-has-key? seen key)
                  (set! duplicate key)
                  (set! seen (hash-set seen key #t))))
            (set! key-start #f)
            (set! expect-key? #f))])]
      [else
       (case byte
         [(34)
          (set! in-string? #t)
          (when (and expect-key? (equal? stack '(123)))
            (set! key-start index))]
         [(123)
          (set! stack (cons byte stack))
          (when (= (length stack) 1)
            (set! expect-key? #t))]
         [(91) (set! stack (cons byte stack))]
         [(125 93)
          (unless (null? stack)
            (set! stack (cdr stack)))]
         [(44)
          (when (equal? stack '(123))
            (set! expect-key? #t))]
         [else (void)])]))
  duplicate)

(define (parse-envelope raw-body environment digest)
  (define duplicate-key (duplicate-top-level-key raw-body))
  (when duplicate-key
    (raise-commerce
     'pancake-payload-invalid
     "verified Pancake webhook payload contains a duplicate top-level field"
     (hash 'payload-digest digest 'field duplicate-key)))
  (define payload
    (with-handlers ([exn:fail?
                     (lambda (_failure)
                       (raise-commerce
                        'pancake-payload-invalid
                        "verified Pancake webhook payload is not valid JSON"
                        (hash 'payload-digest digest)))])
      (bytes->jsexpr raw-body)))
  (unless (hash? payload)
    (raise-commerce
     'pancake-payload-invalid
     "verified Pancake webhook payload must be a JSON object"
     (hash 'payload-digest digest)))
  (for ([field (in-list required-string-fields)])
    (unless (non-empty-string? (hash-ref payload field #f))
      (raise-commerce
       'pancake-payload-invalid
       "verified Pancake webhook payload is missing a required string field"
       (hash 'payload-digest digest 'field field))))
  (unless (hash-has-key? payload 'data)
    (raise-commerce
     'pancake-payload-invalid
     "verified Pancake webhook payload is missing data"
     (hash 'payload-digest digest 'field 'data)))
  (define expected-mode (if (eq? environment 'test) "test" "prod"))
  (unless (equal? (hash-ref payload 'mode #f) expected-mode)
    (raise-commerce
     'pancake-environment-mismatch
     "verified Pancake webhook mode does not match the selected environment"
     (hash 'environment environment 'payload-digest digest)))
  payload)

(define (verify-pancake-webhook
         raw-body
         signature-header
         #:environment environment
         #:keyring [keyring default-pancake-webhook-keyring]
         #:now-ms [now-ms
                   (inexact->exact (floor (current-inexact-milliseconds)))]
         #:past-tolerance-ms [past-tolerance-ms default-past-tolerance-ms]
         #:future-tolerance-ms [future-tolerance-ms default-future-tolerance-ms])
  (unless (bytes? raw-body)
    (raise-arguments-error
     'verify-pancake-webhook
     "raw-body must be bytes"))
  (unless (environment? environment)
    (raise-argument-error
     'verify-pancake-webhook "(or/c 'test 'production)" environment))
  (unless (pancake-webhook-keyring? keyring)
    (raise-argument-error
     'verify-pancake-webhook "pancake-webhook-keyring?" keyring))
  (for ([value (in-list (list now-ms past-tolerance-ms future-tolerance-ms))]
        [description (in-list '("exact-nonnegative-integer? for now-ms"
                                "exact-nonnegative-integer? for past-tolerance-ms"
                                "exact-nonnegative-integer? for future-tolerance-ms"))])
    (unless (exact-nonnegative-integer? value)
      (raise-argument-error 'verify-pancake-webhook description value)))

  ;; Copy before authentication so a caller cannot mutate the accepted bytes
  ;; between signature verification and later audit or parsing.
  (define body (bytes->immutable-bytes (bytes-copy raw-body)))
  (define-values (timestamp-text signature-text)
    (parse-signature-header signature-header))
  (define signature-timestamp-ms (parse-timestamp timestamp-text))
  (check-timestamp-window
   signature-timestamp-ms now-ms past-tolerance-ms future-tolerance-ms)
  (define public-key
    (parse-public-key (public-key-for keyring environment) environment))
  (define signature (decode-signature signature-text environment))
  (define signed-bytes
    (bytes-append
     (string->bytes/utf-8 timestamp-text)
     #"."
     body))
  (verify-signature public-key signed-bytes signature environment)

  ;; Parsing is intentionally after cryptographic authentication.
  (define digest (payload-digest body))
  (define envelope (parse-envelope body environment digest))
  (pancake-webhook
   environment
   (hash-ref envelope 'id)
   (hash-ref envelope 'timestamp)
   (hash-ref envelope 'eventType)
   (hash-ref envelope 'eventId)
   (hash-ref envelope 'storeId)
   (hash-ref envelope 'storeName)
   (hash-ref envelope 'data)
   body
   digest
   signature-timestamp-ms))
