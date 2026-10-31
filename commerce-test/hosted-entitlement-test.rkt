#lang racket/base
(require rackunit
         commerce/storage
         commerce/storage/sqlite
         commerce/hosted-entitlement
         racket/file)

(define (with-storage proc)
  (define dir (make-temporary-file "commerce-hosted-read-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define store (open-sqlite-commerce-storage (build-path dir "db.sqlite")))
     (dynamic-wind void (lambda () (proc store))
                   (lambda () (storage-close store))))
   (lambda () (delete-directory/files dir))))

(test-case "scoped reads default to no access, no existence leak"
  (with-storage
   (lambda (storage)
     (define (read authorize)
       (current-entitlement-snapshot
        storage #:issuer "commerce.example"
        #:subject-type "account" #:subject-id "customer-a"
        #:offer-id "taskly-pro-lifetime" #:authorize authorize))
     (check-exn exn:fail? (lambda () (read (lambda args #f))))
     (check-exn exn:fail? (lambda () (read (lambda args 'yes))))
     (check-equal? (read (lambda (issuer type subject offer)
                           (and (equal? issuer "commerce.example")
                                (equal? type "account")
                                (equal? subject "customer-a")
                                (equal? offer "taskly-pro-lifetime"))))
                   (hasheq 'status "absent")))))


(test-case "authorization sees all four scope fields and denies cross-account reads"
  (with-storage
   (lambda (storage)
     (define seen #f)
     (define (authorize issuer subject-type subject-id offer-id)
       (set! seen (list issuer subject-type subject-id offer-id))
       (and (equal? issuer "commerce.example")
            (equal? subject-type "account")
            (equal? subject-id "customer-a")
            (equal? offer-id "taskly-pro-lifetime")))
     (define (lookup subject-id offer-id)
       (current-entitlement-snapshot
        storage #:issuer "commerce.example" #:subject-type "account"
        #:subject-id subject-id #:offer-id offer-id
        #:authorize authorize))
     (check-exn exn:fail? (lambda () (lookup "customer-b" "taskly-pro-lifetime")))
     (check-equal? seen
                   (list "commerce.example" "account" "customer-b"
                         "taskly-pro-lifetime"))
     (check-exn exn:fail? (lambda () (lookup "customer-a" "other-offer")))
     (check-equal? (lookup "customer-a" "taskly-pro-lifetime")
                   (hasheq 'status "absent")))))
