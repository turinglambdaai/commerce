#lang racket/base

(require rackunit
         commerce
         commerce/provider)

(define usd-10 (money "USD" 1000))

(define (event id digest kind
               #:order [order-id "ord_001"]
               #:offer [offer-id "taskly-pro-lifetime"]
               #:subject [subject-id "customer-001"]
               #:amount [amount usd-10]
               #:at [occurred-at 1])
  (make-verified-payment-event
   "mock" id digest kind order-id offer-id subject-id amount occurred-at))

(define digest-a (make-string 64 #\a))
(define digest-b (make-string 64 #\b))
(define digest-c (make-string 64 #\c))

(test-case "money uses exact minor units"
  (check-equal? (money-minor-units usd-10) 1000)
  (check-exn exn:fail:contract?
             (lambda () (money "usd" 1000)))
  (check-exn exn:fail:contract?
             (lambda () (money "USD" 10.0))))

(test-case "offer identities are stable kebab-case"
  (define candidate
    (offer "taskly-pro-lifetime"
           "taskly"
           'one-time
           usd-10
           "taskly-pro-v1"))
  (check-equal? (offer-product-id candidate) "taskly")
  (check-exn exn:fail:contract?
             (lambda ()
               (offer "Taskly Pro" "taskly" 'one-time usd-10 "policy"))))

(test-case "successful payment emits one grant intent"
  (define-values (state intents)
    (ingest-payment-event
     (empty-commerce-state)
     (event "evt_paid" digest-a 'payment-succeeded #:at 10)))
  (check-equal? (commerce-state-event-count state) 1)
  (check-equal? (commerce-state-order-count state) 1)
  (check-equal? (length intents) 1)
  (check-equal? (rights-intent-action (car intents)) 'grant)
  (define order (commerce-state-order state "mock" "ord_001"))
  (check-true (order-projection-paid? order))
  (check-false (order-projection-refunded? order)))

(test-case "exact webhook replay is a no-op"
  (define paid (event "evt_paid" digest-a 'payment-succeeded))
  (define-values (first-state first-intents)
    (ingest-payment-event (empty-commerce-state) paid))
  (define-values (second-state second-intents)
    (ingest-payment-event first-state paid))
  (check-eq? first-state second-state)
  (check-equal? (length first-intents) 1)
  (check-equal? second-intents '()))

(test-case "same event id with different content fails closed"
  (define-values (state _)
    (ingest-payment-event
     (empty-commerce-state)
     (event "evt_reused" digest-a 'payment-succeeded)))
  (check-exn
   (lambda (failure)
     (and (exn:fail:commerce? failure)
          (eq? (exn:fail:commerce-code failure) 'event-conflict)))
   (lambda ()
     (ingest-payment-event
      state
      (event "evt_reused" digest-b 'payment-refunded)))))

(test-case "provider order cannot change commercial identity"
  (define-values (state _)
    (ingest-payment-event
     (empty-commerce-state)
     (event "evt_paid" digest-a 'payment-succeeded)))
  (check-exn
   (lambda (failure)
     (and (exn:fail:commerce? failure)
          (eq? (exn:fail:commerce-code failure) 'order-conflict)))
   (lambda ()
     (ingest-payment-event
      state
      (event "evt_other"
             digest-b
             'payment-refunded
             #:amount (money "USD" 999))))))

(test-case "refund after payment emits one withdrawal intent"
  (define-values (paid-state _)
    (ingest-payment-event
     (empty-commerce-state)
     (event "evt_paid" digest-a 'payment-succeeded #:at 10)))
  (define-values (refunded-state intents)
    (ingest-payment-event
     paid-state
     (event "evt_refund" digest-b 'payment-refunded #:at 20)))
  (check-equal? (map rights-intent-action intents) '(withdraw))
  (define order (commerce-state-order refunded-state "mock" "ord_001"))
  (check-true (order-projection-paid? order))
  (check-true (order-projection-refunded? order))
  (check-equal? (length (commerce-state-intents refunded-state)) 2))

(test-case "refund before payment never grants rights"
  (define-values (refund-first-state refund-intents)
    (ingest-payment-event
     (empty-commerce-state)
     (event "evt_refund" digest-b 'payment-refunded #:at 20)))
  (check-equal? refund-intents '())
  (define-values (final-state paid-intents)
    (ingest-payment-event
     refund-first-state
     (event "evt_paid" digest-a 'payment-succeeded #:at 10)))
  (check-equal? paid-intents '())
  (define order (commerce-state-order final-state "mock" "ord_001"))
  (check-true (order-projection-paid? order))
  (check-true (order-projection-refunded? order))
  (check-equal? (commerce-state-intents final-state) '()))

(test-case "distinct duplicate success facts do not double grant"
  (define-values (first-state _)
    (ingest-payment-event
     (empty-commerce-state)
     (event "evt_paid_a" digest-a 'payment-succeeded)))
  (define-values (second-state intents)
    (ingest-payment-event
     first-state
     (event "evt_paid_b" digest-c 'payment-succeeded)))
  (check-equal? intents '())
  (check-equal? (length (commerce-state-intents second-state)) 1))

