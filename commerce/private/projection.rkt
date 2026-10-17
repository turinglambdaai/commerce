#lang racket/base

(provide project-order-event)

(require racket/format
         racket/match
         "model.rkt")

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

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
   (format "~a/~a/~a"
           (payment-event-provider event)
           (payment-event-order-id event)
           action)
   action
   (payment-event-provider event)
   (payment-event-order-id event)
   (payment-event-offer-id event)
   (payment-event-subject-id event)
   (payment-event-occurred-at event)))

;; The single-event transition is shared by the in-memory core and durable
;; projector. Delivery replay handling belongs to their respective callers.
(define (project-order-event previous event)
  (unless (or (not previous) (order-projection? previous))
    (raise-argument-error
     'project-order-event "(or/c order-projection? #f)" previous))
  (unless (payment-event? event)
    (raise-argument-error 'project-order-event "payment-event?" event))
  (ensure-order-consistency previous event)
  (define base-order (or previous (initial-order event)))
  (match (payment-event-kind event)
    ['payment-succeeded
     (cond
       [(order-projection-paid? base-order)
        (values base-order '())]
       [(order-projection-refunded? base-order)
        ;; Refund arrived first. Retain both facts, but never grant rights for
        ;; an order already known to be refunded.
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
