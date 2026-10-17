#lang racket/base

(provide
 (struct-out money)
 (struct-out offer)
 payment-event?
 payment-event-provider
 payment-event-event-id
 payment-event-kind
 payment-event-order-id
 payment-event-offer-id
 payment-event-subject-id
 payment-event-amount
 payment-event-occurred-at
 (struct-out order-projection)
 (struct-out rights-intent)
 commerce-state?
 empty-commerce-state
 commerce-state-event-count
 commerce-state-order-count
 commerce-state-intents
 commerce-state-order
 ingest-payment-event
 (struct-out exn:fail:commerce))

(require racket/hash
         "private/model.rkt"
         "private/projection.rkt")

(define (empty-commerce-state)
  (commerce-state (hash) (hash) (hash)))

(define (commerce-state-event-count state)
  (hash-count (commerce-state-events state)))

(define (commerce-state-order-count state)
  (hash-count (commerce-state-orders state)))

(define (commerce-state-intents state)
  (sort (hash-values (commerce-state-rights-intents-by-key state))
        string<?
        #:key rights-intent-idempotency-key))

(define (commerce-state-order state provider order-id)
  (hash-ref (commerce-state-orders state) (cons provider order-id) #f))

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (event-key event)
  (cons (payment-event-provider event) (payment-event-event-id event)))

(define (order-key event)
  (cons (payment-event-provider event) (payment-event-order-id event)))

(define (event-content=? left right)
  (and (equal? (payment-event-payload-digest left)
               (payment-event-payload-digest right))
       (equal? left right)))

;; Returns two values: the new immutable state and the rights intents newly
;; emitted by this transition. An exact replay returns the original state and
;; an empty list, so callers can acknowledge provider retries safely.
(define (ingest-payment-event state event)
  (let/ec return
    (unless (commerce-state? state)
      (raise-argument-error 'ingest-payment-event "commerce-state?" state))
    (unless (payment-event? event)
      (raise-argument-error 'ingest-payment-event "payment-event?" event))

    (define e-key (event-key event))
    (define previous-event
      (hash-ref (commerce-state-events state) e-key #f))
    (when previous-event
      (if (event-content=? previous-event event)
          (return state '())
          (raise-commerce
           'event-conflict
           "provider event id was replayed with different content"
           (hash 'provider (payment-event-provider event)
                 'event-id (payment-event-event-id event)))))

    (define o-key (order-key event))
    (define previous-order
      (hash-ref (commerce-state-orders state) o-key #f))
    (define-values (next-order new-intents)
      (project-order-event previous-order event))

    (define next-events
      (hash-set (commerce-state-events state) e-key event))
    (define next-orders
      (hash-set (commerce-state-orders state) o-key next-order))
    (define next-intents
      (for/fold ([intents (commerce-state-rights-intents-by-key state)])
                ([intent (in-list new-intents)])
        (hash-set intents (rights-intent-idempotency-key intent) intent)))
    (values (commerce-state next-events next-orders next-intents)
            new-intents)))

