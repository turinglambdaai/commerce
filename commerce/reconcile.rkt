#lang racket/base

(provide
 reconciliation-difference?
 reconciliation-difference-order-id
 reconciliation-difference-code
 reconciliation-difference-detail
 reconcile-orders)

(require racket/list
         "pancake.rkt"
         "storage.rkt"
         "private/model.rkt")

;; Reconciliation compares bounded provider order facts with local
;; projections and reports unexplained differences. It never mutates
;; journal, projection, or outbox state: a difference is an operator
;; signal, and missing facts still enter through the webhook/journal path.

(struct reconciliation-difference
  (order-id code detail)
  #:transparent)

(define (reconcile-orders storage client orders)
  (unless (commerce-storage? storage)
    (raise-argument-error 'reconcile-orders "commerce-storage?" storage))
  (unless (pancake-merchant-client? client)
    (raise-argument-error
     'reconcile-orders "pancake-merchant-client?" client))
  (unless (and (list? orders)
               (andmap
                (lambda (entry)
                  (and (pair? entry)
                       (opaque-id? (car entry))
                       (pancake-order-binding? (cdr entry))))
                orders))
    (raise-argument-error
     'reconcile-orders
     "(listof (cons/c opaque-id? pancake-order-binding?))"
     orders))
  (filter
   values
   (for/list ([entry (in-list orders)])
    (define order-id (car entry))
    (define binding (cdr entry))
    (define (read-difference)
      (with-handlers
          ([exn:fail:commerce?
            (lambda (failure)
              (define code (exn:fail:commerce-code failure))
              (cond
                [(eq? code 'pancake-order-not-found)
                 (reconciliation-difference
                  order-id 'provider-order-not-found (hash))]
                [(eq? code 'pancake-order-unavailable)
                 ;; Retryable transport problems are not differences; the
                 ;; next reconciliation pass re-reads them.
                 #f]
                [else
                 (reconciliation-difference
                  order-id 'provider-read-refused
                  (hash 'code code))]))])
        (define facts
          (read-pancake-onetime-order client order-id))
        (define projection
          (storage-order-ref storage
                             (pancake-order-binding->provider binding)
                             order-id))
        (define paid?
          (and (equal? (pancake-order-facts-status facts) "completed")
               (equal? (pancake-order-facts-payment-status facts)
                       "succeeded")))
        (cond
          [(or (not projection) (not (order-projection-paid? projection)))
           (and paid?
                (reconciliation-difference
                 order-id 'missing-webhook
                 (hash 'provider-status
                       (pancake-order-facts-status facts))))]
          [(and (order-projection-paid? projection)
                (not (order-projection-refunded? projection))
                (not paid?))
           (reconciliation-difference
            order-id 'provider-disagrees
            (hash 'provider-status (pancake-order-facts-status facts)
                  'payment-status
                  (pancake-order-facts-payment-status facts)))]
          [else #f])))
     (read-difference))))

(define (pancake-order-binding->provider binding)
  ;; Pancake facts are only ever compared against the adapter that owns
  ;; the checkout; the provider name lives with the checkout flow.
  "pancake")
