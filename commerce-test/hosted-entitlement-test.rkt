#lang racket/base
(require rackunit
         commerce
         commerce/provider
         commerce/journal
         commerce/storage
         commerce/storage/sqlite
         commerce/hosted-entitlement
         crypto
         crypto/libcrypto
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

(define (digest raw)
  (bytes->hex-string
   (parameterize ([crypto-factories (list libcrypto-factory)])
     (digest 'sha256 raw))))

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
