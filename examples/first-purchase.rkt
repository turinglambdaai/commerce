#lang racket/base

(require commerce
         commerce/provider)

(define paid
  (make-verified-payment-event
   "mock"
   "evt_demo_paid"
   (make-string 64 #\a)
   'payment-succeeded
   "ord_demo_001"
   "taskly-pro-lifetime"
   "customer-demo"
   (money "USD" 2900)
   1792108800))

(define-values (paid-state intents)
  (ingest-payment-event (empty-commerce-state) paid))

(define order
  (commerce-state-order paid-state "mock" "ord_demo_001"))
(printf "order ~a: ~a\n"
        (order-projection-order-id order)
        (if (order-projection-paid? order) 'paid 'pending))

(for ([intent (in-list intents)])
  (printf "rights intent: ~a ~a to ~a\n"
          (rights-intent-action intent)
          (rights-intent-offer-id intent)
          (rights-intent-subject-id intent)))

(define-values (_ replay-intents)
  (ingest-payment-event paid-state paid))
(printf "duplicate webhook: ~a\n"
        (if (null? replay-intents) 'ignored 'unexpected))

