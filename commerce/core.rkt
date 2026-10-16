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

(require racket/format
         racket/hash
         racket/match
         "private/model.rkt")

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

(define (intent-key event action)
  (format "~a/~a/~a"
          (payment-event-provider event)
          (payment-event-order-id event)
          action))

(define (event-content=? left right)
  (and (equal? (payment-event-payload-digest left)
               (payment-event-payload-digest right))
       (equal? left right)))

(define (ensure-order-consistency previous event)
  (when previous
    (define same?
      (and (equal? (order-projection-offer-id previous)
                   (payment-event-offer-id event))
           (equal? (order-projection-subject-id previous)
                   (payment-event-subject-id event))
           (equal? (order-projection-amount previous)
                   (payment-event-amount event))))
    (unless same?
      (raise-commerce
       'order-conflict
       "provider order changed offer, subject, or amount across events"
       (hash 'provider (payment-event-provider event)
             'order-id (payment-event-order-id event))))))

(define (initial-order event)
  (order-projection
   (payment-event-provider event)
   (payment-event-order-id event)
   (payment-event-offer-id event)
   (payment-event-subject-id event)
   (payment-event-amount event)
   #f #f #f #f))

(define (make-intent event action)
  (rights-intent
   (intent-key event action)
   action
   (payment-event-provider event)
   (payment-event-order-id event)
   (payment-event-offer-id event)
   (payment-event-subject-id event)
   (payment-event-occurred-at event)))

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
    (ensure-order-consistency previous-order event)
    (define base-order (or previous-order (initial-order event)))

    (define-values (next-order new-intents)
      (match (payment-event-kind event)
        ['payment-succeeded
         (cond
           [(order-projection-paid? base-order)
            (values base-order '())]
           [(order-projection-refunded? base-order)
            ;; Refund arrived first. Retain both facts, but never grant rights
            ;; for an order already known to be refunded.
           (values
            (struct-copy order-projection base-order
                         [paid? #t]
                         [paid-at (payment-event-occurred-at event)])
            '())]
           [else
            (define intent (make-intent event 'grant))
            (values
             (struct-copy order-projection base-order
                          [paid? #t]
                          [paid-at (payment-event-occurred-at event)])
             (list intent))])]
        ['payment-refunded
         (cond
           [(order-projection-refunded? base-order)
            (values base-order '())]
           [(order-projection-paid? base-order)
            (define intent (make-intent event 'withdraw))
            (values
             (struct-copy order-projection base-order
                          [refunded? #t]
                          [refunded-at (payment-event-occurred-at event)])
             (list intent))]
           [else
            (values
             (struct-copy order-projection base-order
                          [refunded? #t]
                          [refunded-at (payment-event-occurred-at event)])
             '())])]))

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

