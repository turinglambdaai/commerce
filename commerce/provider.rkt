#lang racket/base

(provide
 make-verified-payment-event
 (struct-out checkout-session)
 (struct-out provider-adapter))

(require "private/model.rkt")

;; This constructor lives outside the default facade on purpose. A production
;; adapter calls it only after native signature verification, payload parsing,
;; amount checks, and provider/order lookup required by its contract.
(define make-verified-payment-event payment-event)

