#lang racket/base

(provide
 make-verified-payment-event
 (struct-out checkout-session)
 (struct-out provider-adapter))

(require "private/model.rkt")

;; This constructor lives outside the default facade on purpose. A production
;; adapter calls it only after native signature verification, payload parsing,
;; amount checks, and provider/order lookup required by its contract. For a
;; one-time fact, paid-through stays #f; a subscription payment reports the
;; epoch second through which the provider says access is paid.
(define (make-verified-payment-event
         provider event-id payload-digest kind order-id offer-id subject-id
         amount occurred-at
         #:paid-through [paid-through #f])
  (payment-event provider event-id payload-digest kind order-id offer-id
                 subject-id amount occurred-at paid-through))

