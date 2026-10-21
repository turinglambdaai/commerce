#lang racket/base

;; gptp-studio — the family's first paid product — as a worked offer:
;; a perpetual Pro edition whose updates window is one year of paid
;; evidence, not a policy-fixed date. Run: racket examples/gptp-studio-updates-window.rkt
;;
;; The journey mirrors first-purchase.rkt (mock provider, ingest, order
;; projection) and then prepares the issuance snapshot the worker would
;; sign, asserting the two properties the product gate relies on: the
;; updates window derives from the order's paid-at instant, and the same
;; order replays to the same window bytes.

(require commerce
         commerce/provider
         commerce/permit)

(define paid-at 1792108800) ; 2026-10-16T00:00:00Z

;; The reviewed, version-pinned Offer policy. The window is a duration,
;; so every purchase gets its own anniversary — the policy id stays
;; immutable while the concrete date is issuance-time order evidence.
(define catalog
  (make-permit-policy-catalog
   (list (offer "gptp-studio-pro-perpetual" "gptp-studio" 'one-time
                (money "CNY" 39900) "gptp-studio-pro-v1")
         (offer "gptp-studio-pro-team-5" "gptp-studio" 'one-time
                (money "CNY" 159900) "gptp-studio-pro-team-v1"))
   (list
    (make-permit-entitlement-policy
     "gptp-studio-pro-v1" 1
     #:subject-type 'person
     #:grants
     (list (make-permit-grant-policy
            #:products '("gptp-studio") #:edition "pro"))
     #:constraints
     (make-permit-constraints-policy
      #:updates-through-duration-days 365))
    (make-permit-entitlement-policy
     "gptp-studio-pro-team-v1" 1
     #:subject-type 'person
     #:grants
     (list (make-permit-grant-policy
            #:products '("gptp-studio") #:edition "pro"))
     #:constraints
     (make-permit-constraints-policy
      #:updates-through-duration-days 365
      #:named-seats 5)))))

(define paid
  (make-verified-payment-event
   "mock"
   "evt_gptp_paid"
   (make-string 64 #\a)
   'payment-succeeded
   "ord_gptp_001"
   "gptp-studio-pro-perpetual"
   "customer-gptp-001"
   (money "CNY" 39900)
   paid-at))

(define-values (paid-state intents)
  (ingest-payment-event (empty-commerce-state) paid))
(define order
  (commerce-state-order paid-state "mock" "ord_gptp_001"))
(printf "order ~a: paid-at ~a\n"
        (order-projection-order-id order)
        (order-projection-paid-at order))

(define snapshot
  (permit-snapshot-request-payload
   (prepare-permit-snapshot
    catalog
    (car intents)
    #:issuer "com.turinglambdaai.gptp-studio"
    #:credential-id "cred-gptp-001-r0"
    #:entitlement-id "ent-gptp-001"
    #:issued-at "2026-10-16T00:05:00Z"
    #:paid-at (order-projection-paid-at order))))
(printf "updates_through: ~a\n"
        (hash-ref (hash-ref snapshot 'constraints) 'updates_through))

;; Replaying the same order derives the same window bytes.
(define replay
  (permit-snapshot-request-payload
   (prepare-permit-snapshot
    catalog
    (car intents)
    #:issuer "com.turinglambdaai.gptp-studio"
    #:credential-id "cred-gptp-001-r0"
    #:entitlement-id "ent-gptp-001"
    #:issued-at "2026-10-16T00:05:00Z"
    #:paid-at (order-projection-paid-at order))))
(printf "replay stable: ~a\n"
        (equal? (hash-ref (hash-ref replay 'constraints) 'updates_through)
                (hash-ref (hash-ref snapshot 'constraints) 'updates_through)))
