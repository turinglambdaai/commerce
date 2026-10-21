#lang racket/base

(provide
 issuance-worker?
 make-issuance-worker
 process-issuance-work!
 issuance-result?
 issuance-result-disposition
 issuance-result-completion
 issuance-result-error-code
 issuance-result-entitlement-id
 issuance-result-revision
 issuance-result-claim-token
 derive-entitlement-id
 derive-credential-id)

(require (only-in crypto crypto-random-bytes)
         file/sha1
         json
         racket/match
         racket/port
         permit/envelope
         permit/issuer
         "permit.rkt"
         "storage.rkt"
         "private/model.rkt")

;; The worker owns no durable state of its own. Every decision is derived
;; from the claimed outbox row, the pinned policy catalog, and the lineage
;; already recorded in storage, so a restart or a reclaim converges on the
;; same revision instead of creating a second one.

(struct issuance-worker
  (catalog issuer private-key key-id trust-store clock
           owner lease-seconds transient-backoff-seconds
           operator-backoff-seconds claim-window-seconds)
  #:transparent)

;; disposition is 'completed, 'released, or 'lease-lost. A released result
;; names the typed error code that future operators will see on the outbox
;; row; completion exposes the storage completion record.
(struct issuance-result
  (disposition completion error-code entitlement-id revision claim-token)
  #:transparent)

(define (pad2 value)
  (if (< value 10) (string-append "0" (number->string value))
      (number->string value)))

(define (rfc3339 epoch-seconds)
  (define moment (seconds->date epoch-seconds #t))
  (string-append
   (number->string (date-year moment))
   "-" (pad2 (date-month moment))
   "-" (pad2 (date-day moment))
   "T" (pad2 (date-hour moment))
   ":" (pad2 (date-minute moment))
   ":" (pad2 (date-second moment)) "Z"))

(define default-clock
  (lambda ()
    (define now (current-seconds))
    (values now (rfc3339 now))))

(define (make-issuance-worker
         #:catalog catalog
         #:issuer issuer
         #:private-key private-key
         #:key-id key-id
         #:trust-store trust-store
         #:clock [clock default-clock]
         #:owner [owner "commerce-issuer"]
         #:lease-seconds [lease-seconds 30]
         #:transient-backoff-seconds [transient-backoff-seconds 30]
         #:operator-backoff-seconds [operator-backoff-seconds 3600]
         #:claim-window-seconds [claim-window-seconds 2592000])
  (unless (permit-policy-catalog? catalog)
    (raise-argument-error
     'make-issuance-worker "permit-policy-catalog?" catalog))
  (unless (opaque-id? issuer)
    (raise-argument-error
     'make-issuance-worker
     "non-empty opaque issuer up to 256 characters"
     issuer))
  (unless private-key
    (raise-argument-error
     'make-issuance-worker "ed25519 private key" private-key))
  (unless (and (string? key-id) (positive? (string-length key-id)))
    (raise-argument-error 'make-issuance-worker "non-empty key id" key-id))
  (unless (trust-store? trust-store)
    (raise-argument-error 'make-issuance-worker "trust-store?" trust-store))
  (unless (procedure? clock)
    (raise-argument-error 'make-issuance-worker "procedure?" clock))
  (unless (opaque-id? owner)
    (raise-argument-error
     'make-issuance-worker "non-empty opaque owner up to 256 characters" owner))
  (unless (exact-positive-integer? lease-seconds)
    (raise-argument-error
     'make-issuance-worker "exact-positive-integer?" lease-seconds))
  (unless (exact-positive-integer? transient-backoff-seconds)
    (raise-argument-error
     'make-issuance-worker "exact-positive-integer?" transient-backoff-seconds))
  (unless (exact-positive-integer? operator-backoff-seconds)
    (raise-argument-error
     'make-issuance-worker "exact-positive-integer?" operator-backoff-seconds))
  (unless (exact-positive-integer? claim-window-seconds)
    (raise-argument-error
     'make-issuance-worker "exact-positive-integer?" claim-window-seconds))
  (issuance-worker catalog issuer private-key key-id trust-store clock
                   owner lease-seconds transient-backoff-seconds
                   operator-backoff-seconds claim-window-seconds))

;; Deterministic lineage ids. The same issuer, subject, and Offer must
;; always derive the same entitlement id, and one revision of that lineage
;; must always derive the same credential id, so a crash after signing
;; reconciles instead of duplicating (ADR-0009).
(define (derive-entitlement-id issuer subject-type subject-id offer-id)
  (define digest
    (bytes->hex-string
     (sha256-bytes
      (string->bytes/utf-8
       (string-append "commerce-entitlement-v1\x00" issuer "\x00"
                      subject-type "\x00" subject-id "\x00" offer-id)))))
  (string-append "ent-" (substring digest 0 32)))

(define (derive-credential-id entitlement-id revision)
  (define digest
    (bytes->hex-string
     (sha256-bytes
      (string->bytes/utf-8
       (string-append "commerce-credential-v1\x00" entitlement-id
                      "\x00" (number->string revision))))))
  (string-append "cred-" (substring digest 0 32)))

(define (released-result error-code)
  (issuance-result 'released #f error-code #f #f #f))

;; Drives one due outbox row through snapshot preparation, signing, and the
;; transactional lineage writer. Signing happens outside the claim
;; transaction; completion is owner-checked by storage. Nothing about the
;; signed envelope is persisted by this boundary.
(define (process-issuance-work! worker storage)
  (unless (issuance-worker? worker)
    (raise-argument-error 'process-issuance-work! "issuance-worker?" worker))
  (unless (commerce-storage? storage)
    (raise-argument-error 'process-issuance-work! "commerce-storage?" storage))
  (define-values (claim-now _claim-issued-at)
    ((issuance-worker-clock worker)))
  (define item
    (storage-claim-issuance-work! storage
                                  #:owner (issuance-worker-owner worker)
                                  #:lease-seconds
                                  (issuance-worker-lease-seconds worker)
                                  #:now claim-now))
  (cond
    [(not item) #f]
    [else
     (drive-claimed-work! worker storage item claim-now)]))

;; Resolves the claimed row's Offer policy and lineage, refuses deterministic
;; dead ends before any signing work, and hands the rest to the signing path.
(define (drive-claimed-work! worker storage item claim-now)
  (define issuer (issuance-worker-issuer worker))
  (define offer-id (issuance-outbox-item-offer-id item))
  (define subject-id (issuance-outbox-item-subject-id item))
  (define action (issuance-outbox-item-action item))
  (define intent
    (rights-intent
     (issuance-outbox-item-idempotency-key item)
     action
     (issuance-outbox-item-provider item)
     (issuance-outbox-item-order-id item)
     offer-id
     subject-id
     (issuance-outbox-item-occurred-at item)))
  (define (release-failure! failure)
    (storage-release-issuance-work! storage item
                                    #:error-code
                                    (exn:fail:commerce-code failure)
                                    #:retry-at
                                    (+ claim-now
                                       (issuance-worker-operator-backoff-seconds
                                        worker)))
    (released-result (exn:fail:commerce-code failure)))
  (with-handlers
      ([exn:fail:commerce? release-failure!])
    (define policy
      (permit-policy-for-offer (issuance-worker-catalog worker) offer-id))
    (define subject-type
      (symbol->string (permit-entitlement-policy-subject-type policy)))
    (define lineage
      (storage-lineage-ref storage
                           #:issuer issuer
                           #:subject-type subject-type
                           #:subject-id subject-id
                           #:offer-id offer-id))
    (define entitlement-id
      (if lineage
          (entitlement-lineage-entitlement-id lineage)
          (derive-entitlement-id issuer subject-type subject-id offer-id)))
    (define latest
      (storage-latest-entitlement-revision storage entitlement-id))
    ;; Deterministic refusals stop before any signing work.
    (cond
      [(and (eq? action 'grant) lineage)
       (release-deterministic! worker storage item claim-now
                               'entitlement-lineage-conflict)]
      [(and (eq? action 'withdraw) (not lineage))
       (release-deterministic! worker storage item claim-now
                               'entitlement-lineage-required)]
      [else
       (drive-issuance! worker storage item intent issuer subject-type
                        entitlement-id latest claim-now)])))

(define (release-deterministic! worker storage item now error-code)
  (storage-release-issuance-work! storage item
                                  #:error-code error-code
                                  #:retry-at
                                  (+ now
                                     (issuance-worker-operator-backoff-seconds
                                      worker)))
  (released-result error-code))

(define (release-commerce-failure worker storage item now failure)
  (define code (exn:fail:commerce-code failure))
  (storage-release-issuance-work! storage item
                                  #:error-code code
                                  #:retry-at
                                  (+ now
                                     (issuance-worker-operator-backoff-seconds
                                      worker)))
  (released-result code))

(define (drive-issuance! worker storage item intent issuer subject-type
                         entitlement-id latest claim-now)
  (define action (rights-intent-action intent))
  (define revision
    (if latest
        (add1 (entitlement-revision-revision latest))
        0))
  (define credential-id
    (derive-credential-id entitlement-id revision))
  (define-values (issued-at issued-at-string)
    ((issuance-worker-clock worker)))
  (define previous
    (and (eq? action 'withdraw)
         (with-input-from-bytes
             (entitlement-revision-payload-bytes latest)
           read-json)))
  (define snapshot
    (prepare-permit-snapshot
     (issuance-worker-catalog worker)
     intent
     #:issuer issuer
     #:credential-id credential-id
     #:entitlement-id entitlement-id
     #:issued-at issued-at-string
     #:previous previous))
  ;; Signing happens outside the claim transaction. Ed25519 signing is
  ;; deterministic, so if this process dies after signing, the reclaiming
  ;; worker re-signs the same bytes and the recorded revision converges.
  (with-handlers
      ([exn:fail:permit:issue?
        (lambda (_failure)
          (storage-release-issuance-work! storage item
                                          #:error-code 'permit-issue-failed
                                          #:retry-at
                                          (+ issued-at
                                             (issuance-worker-transient-backoff-seconds
                                              worker)))
          (released-result 'permit-issue-failed))])
    (define envelope
      (issue-credential
       (permit-snapshot-request-payload-bytes snapshot)
       (issuance-worker-private-key worker)
       (issuance-worker-key-id worker)
       (issuance-worker-trust-store worker)))
    ;; The claim token is generated once here, delivered to the caller for
    ;; exactly one customer handoff, and stored only as a digest.
    (define claim-token
      (bytes->hex-string (crypto-random-bytes 16)))
    (with-handlers
        ([exn:fail:commerce?
          (lambda (failure)
            (if (eq? (exn:fail:commerce-code failure) 'lease-not-held)
                (issuance-result 'lease-lost #f #f entitlement-id revision
                                 #f)
                (release-commerce-failure worker storage item issued-at
                                          failure)))])
      (define completion
        (storage-complete-issuance-work! storage item
                                         #:issuer issuer
                                         #:subject-type subject-type
                                         #:entitlement-id entitlement-id
                                         #:credential-id credential-id
                                         #:policy-id
                                         (permit-snapshot-request-policy-id
                                          snapshot)
                                         #:policy-version
                                         (permit-snapshot-request-policy-version
                                          snapshot)
                                         #:payload-bytes
                                         (permit-snapshot-request-payload-bytes
                                          snapshot)
                                         #:issued-at issued-at-string
                                         #:recorded-at issued-at
                                         #:signed-credential-bytes
                                         (with-output-to-bytes
                                           (lambda ()
                                             (write-json
                                              (envelope->jsexpr envelope))))
                                         #:key-id
                                         (issuance-worker-key-id worker)
                                         #:claim-token claim-token
                                         #:claim-expires-at
                                         (+ issued-at
                                            (issuance-worker-claim-window-seconds
                                             worker))))
      (issuance-result 'completed completion #f entitlement-id
                       (entitlement-revision-revision
                        (issuance-completion-revision completion))
                       claim-token))))
