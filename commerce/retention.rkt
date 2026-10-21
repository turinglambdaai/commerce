#lang racket/base

(provide retire-expired-claims!)

(require "storage.rkt")

;; Retention of expired one-time claims. Commerce's retention story has two
;; halves: status transitions this boundary owns, and deletion of durable
;; evidence, which stays a versioned, audited schema operation documented in
;; operations.md. Claims whose fulfillment window passed move to `expired`
;; and remain as audit rows; fulfillment refuses them either way.

(define (retire-expired-claims! storage #:now now)
  (storage-retire-expired-claims! storage #:now now))
