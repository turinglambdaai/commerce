#lang racket/base

(provide
 commerce-storage?
 projection-result?
 projection-result-disposition
 projection-result-journal-sequence
 projection-result-order
 projection-result-outbox
 projection-result-failure-code
 issuance-outbox-item?
 issuance-outbox-item-id
 issuance-outbox-item-idempotency-key
 issuance-outbox-item-source-sequence
 issuance-outbox-item-action
 issuance-outbox-item-provider
 issuance-outbox-item-order-id
 issuance-outbox-item-offer-id
 issuance-outbox-item-subject-id
 issuance-outbox-item-occurred-at
 issuance-outbox-item-status
 issuance-outbox-item-attempts
 issuance-outbox-item-available-at
 issuance-outbox-item-lease-owner
 issuance-outbox-item-lease-expires-at
 issuance-outbox-item-last-error-code
 issuance-outbox-item-created-at
 issuance-outbox-item-updated-at
 issuance-outbox-item-completed-at
 entitlement-lineage?
 entitlement-lineage-entitlement-id
 entitlement-lineage-issuer
 entitlement-lineage-subject-type
 entitlement-lineage-subject-id
 entitlement-lineage-offer-id
 entitlement-lineage-created-at
 entitlement-revision?
 entitlement-revision-entitlement-id
 entitlement-revision-revision
 entitlement-revision-previous-revision
 entitlement-revision-credential-id
 entitlement-revision-issuance-outbox-id
 entitlement-revision-action
 entitlement-revision-policy-id
 entitlement-revision-policy-version
 entitlement-revision-payload-bytes
 entitlement-revision-payload-digest
 entitlement-revision-issued-at
 entitlement-revision-recorded-at
 issuance-completion?
 issuance-completion-outbox
 issuance-completion-revision
 issued-credential-record?
 issued-credential-record-id
 issued-credential-record-issuance-outbox-id
 issued-credential-record-entitlement-id
 issued-credential-record-revision
 issued-credential-record-credential-id
 issued-credential-record-key-id
 issued-credential-record-envelope-bytes
 issued-credential-record-created-at
 claim-fulfillment?
 claim-fulfillment-claim-id
 claim-fulfillment-credential
 claim-fulfillment-claimed-at
 storage-project-next!
 storage-claim-issuance-work!
 storage-complete-issuance-work!
 storage-release-issuance-work!
 storage-order-ref
 storage-outbox-ref
 storage-entitlement-ref
 storage-lineage-ref
 storage-entitlement-revision-ref
 storage-latest-entitlement-revision
 storage-claim-credential
 storage-mark-claim-notified
 storage-close)

(require racket/list
         "private/model.rkt"
         "private/storage-model.rkt")

(define (check-storage who storage)
  (unless (commerce-storage? storage)
    (raise-argument-error who "commerce-storage?" storage)))

(define (check-claimed-work who item)
  (unless (issuance-outbox-item? item)
    (raise-argument-error who "issuance-outbox-item?" item)))

(define (check-timestamp who value)
  (unless (exact-nonnegative-integer? value)
    (raise-argument-error
     who "exact-nonnegative-integer?" value)))

(define (check-typed-code who value)
  (unless (stable-id? (if (symbol? value) (symbol->string value) ""))
    (raise-argument-error
     who "stable kebab-case error symbol" value))
  value)

(define (storage-project-next! storage #:processed-at processed-at)
  (check-storage 'storage-project-next! storage)
  (unless (exact-nonnegative-integer? processed-at)
    (raise-argument-error
     'storage-project-next! "exact-nonnegative-integer?" processed-at))
  ((commerce-storage-project-next storage) processed-at))

(define (storage-order-ref storage provider order-id)
  (check-storage 'storage-order-ref storage)
  (unless (stable-id? provider)
    (raise-argument-error
     'storage-order-ref "stable kebab-case provider identifier" provider))
  (unless (opaque-id? order-id)
    (raise-argument-error
     'storage-order-ref "non-empty opaque provider order identifier" order-id))
  ((commerce-storage-order-lookup storage) provider order-id))

(define (storage-outbox-ref storage idempotency-key)
  (check-storage 'storage-outbox-ref storage)
  (unless (and (string? idempotency-key)
               (<= 1 (string-length idempotency-key) 512))
    (raise-argument-error
     'storage-outbox-ref "non-empty idempotency key up to 512 characters"
     idempotency-key))
  ((commerce-storage-outbox-lookup storage) idempotency-key))

;; Claims the lowest due outbox row for one owner. Active leases are
;; exclusive; an expired lease may be reclaimed by any owner, and the
;; reclaim is observable through the attempts counter.
(define (storage-claim-issuance-work! storage
                                      #:owner owner
                                      #:lease-seconds lease-seconds
                                      #:now now)
  (check-storage 'storage-claim-issuance-work! storage)
  (unless (opaque-id? owner)
    (raise-argument-error
     'storage-claim-issuance-work!
     "non-empty opaque owner identifier up to 256 characters"
     owner))
  (unless (exact-positive-integer? lease-seconds)
    (raise-argument-error
     'storage-claim-issuance-work! "exact-positive-integer?" lease-seconds))
  (check-timestamp 'storage-claim-issuance-work! now)
  ((commerce-storage-issuance-claim storage) owner lease-seconds now))

;; Appends the lineage root with revision zero, or exactly one successor,
;; and completes the claimed work in one transaction. The claimed item
;; carries the lease owner that completion re-checks against the database.
;; When the caller also supplies the exact signed envelope bytes, the same
;; transaction records the issued credential and — with a one-time claim
;; token and expiry — its fulfillment claim; only the token's SHA-256
;; digest is ever stored.
(define (storage-complete-issuance-work! storage item
                                         #:issuer issuer
                                         #:subject-type subject-type
                                         #:entitlement-id entitlement-id
                                         #:credential-id credential-id
                                         #:policy-id policy-id
                                         #:policy-version policy-version
                                         #:payload-bytes payload-bytes
                                         #:issued-at issued-at
                                         #:recorded-at recorded-at
                                         #:signed-credential-bytes
                                         [signed-credential-bytes #f]
                                         #:key-id [key-id #f]
                                         #:claim-token [claim-token #f]
                                         #:claim-expires-at
                                         [claim-expires-at #f])
  (check-storage 'storage-complete-issuance-work! storage)
  (check-claimed-work 'storage-complete-issuance-work! item)
  (for ([label/value
        (in-list
         (list (list "issuer" issuer)
               (list "subject type" subject-type)
               (list "entitlement id" entitlement-id)
               (list "credential id" credential-id)
               (list "policy id" policy-id)))]
        #:unless (opaque-id? (second label/value)))
    (raise-argument-error
     'storage-complete-issuance-work!
     (format "non-empty opaque ~a up to 256 characters" (first label/value))
     (second label/value)))
  (unless (exact-positive-integer? policy-version)
    (raise-argument-error
     'storage-complete-issuance-work!
     "exact-positive-integer?" policy-version))
  (unless (and (bytes? payload-bytes) (> (bytes-length payload-bytes) 0))
    (raise-argument-error
     'storage-complete-issuance-work!
     "non-empty bytes?" payload-bytes))
  (unless (and (string? issued-at) (<= 1 (string-length issued-at) 512))
    (raise-argument-error
     'storage-complete-issuance-work!
     "non-empty Permit issued-at string up to 512 characters" issued-at))
  (check-timestamp 'storage-complete-issuance-work! recorded-at)
  (when signed-credential-bytes
    (unless (and (bytes? signed-credential-bytes)
                 (> (bytes-length signed-credential-bytes) 0))
      (raise-argument-error
       'storage-complete-issuance-work!
       "non-empty bytes?" signed-credential-bytes))
    (unless (opaque-id? key-id)
      (raise-argument-error
       'storage-complete-issuance-work!
       "non-empty opaque key id up to 256 characters" key-id)))
  (when claim-token
    (unless signed-credential-bytes
      (raise-argument-error
       'storage-complete-issuance-work!
       "signed credential bytes are required to record a claim"
       claim-token))
    (unless (and (string? claim-token)
                 (<= 1 (string-length claim-token) 512))
      (raise-argument-error
       'storage-complete-issuance-work!
       "non-empty claim token up to 512 characters" claim-token))
    (unless (exact-nonnegative-integer? claim-expires-at)
      (raise-argument-error
       'storage-complete-issuance-work!
       "exact-nonnegative-integer?" claim-expires-at)))
  ((commerce-storage-issuance-complete storage)
   item issuer subject-type entitlement-id credential-id policy-id
   policy-version (bytes->immutable-bytes payload-bytes) issued-at
   recorded-at
   (and signed-credential-bytes
        (bytes->immutable-bytes signed-credential-bytes))
   key-id claim-token claim-expires-at))

;; Returns transient work to 'pending with a typed error and a future retry
;; time. Only the lease owner may release, and the attempts counter is left
;; exactly as the claim incremented it.
(define (storage-release-issuance-work! storage item
                                        #:error-code error-code
                                        #:retry-at retry-at)
  (check-storage 'storage-release-issuance-work! storage)
  (check-claimed-work 'storage-release-issuance-work! item)
  (check-typed-code 'storage-release-issuance-work! error-code)
  (check-timestamp 'storage-release-issuance-work! retry-at)
  ((commerce-storage-issuance-release storage) item error-code retry-at))

(define (storage-entitlement-ref storage entitlement-id)
  (check-storage 'storage-entitlement-ref storage)
  (unless (opaque-id? entitlement-id)
    (raise-argument-error
     'storage-entitlement-ref
     "non-empty opaque entitlement identifier" entitlement-id))
  ((commerce-storage-entitlement-lookup storage) entitlement-id))

(define (storage-lineage-ref storage
                             #:issuer issuer
                             #:subject-type subject-type
                             #:subject-id subject-id
                             #:offer-id offer-id)
  (check-storage 'storage-lineage-ref storage)
  (for ([label/value
         (in-list
          (list (list "issuer" issuer)
                (list "subject type" subject-type)
                (list "subject id" subject-id)
                (list "offer id" offer-id)))]
        #:unless (opaque-id? (second label/value)))
    (raise-argument-error
     'storage-lineage-ref
     (format "non-empty opaque ~a up to 256 characters" (first label/value))
     (second label/value)))
  ((commerce-storage-lineage-lookup storage)
   issuer subject-type subject-id offer-id))

(define (storage-entitlement-revision-ref storage entitlement-id revision)
  (check-storage 'storage-entitlement-revision-ref storage)
  (unless (opaque-id? entitlement-id)
    (raise-argument-error
     'storage-entitlement-revision-ref
     "non-empty opaque entitlement identifier" entitlement-id))
  (check-timestamp 'storage-entitlement-revision-ref revision)
  ((commerce-storage-revision-lookup storage) entitlement-id revision))

(define (storage-latest-entitlement-revision storage entitlement-id)
  (check-storage 'storage-latest-entitlement-revision storage)
  (unless (opaque-id? entitlement-id)
    (raise-argument-error
     'storage-latest-entitlement-revision
     "non-empty opaque entitlement identifier" entitlement-id))
  ((commerce-storage-latest-revision-lookup storage) entitlement-id))

;; Fulfills a one-time claim: verifies the token, its state, and its window,
;; marks the claim fulfilled, and returns the exact signed envelope bytes.
;; Fulfillment never creates or changes a lineage revision.
(define (storage-claim-credential storage #:token token #:now now)
  (check-storage 'storage-claim-credential storage)
  (unless (and (string? token) (<= 1 (string-length token) 512))
    (raise-argument-error
     'storage-claim-credential
     "non-empty claim token up to 512 characters" token))
  (check-timestamp 'storage-claim-credential now)
  ((commerce-storage-claim-lookup storage) token now))

;; Records that a delivery transport handed the claim token out. The first
;; notification timestamp wins; later retries are idempotent no-ops.
(define (storage-mark-claim-notified storage #:token token #:now now)
  (check-storage 'storage-mark-claim-notified storage)
  (unless (and (string? token) (<= 1 (string-length token) 512))
    (raise-argument-error
     'storage-mark-claim-notified
     "non-empty claim token up to 512 characters" token))
  (check-timestamp 'storage-mark-claim-notified now)
  ((commerce-storage-claim-notified storage) token now))

(define (storage-close storage)
  (check-storage 'storage-close storage)
  ((commerce-storage-close storage)))
