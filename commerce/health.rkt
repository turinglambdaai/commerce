#lang racket/base

(provide
 (struct-out health-warning)
 (struct-out health-status)
 health-report
 health-report!)

(require "log.rkt"
         "storage.rkt"
         "private/storage-model.rkt")

;; Readiness for health endpoints and stuck-work inspection. The report is
;; read-only: it classifies the current snapshot and never repairs anything.
;; An HTTP edge (a future commerce/server slice) would render this value;
;; the classification itself is transport-neutral.

(struct health-warning (code detail) #:transparent)

(struct health-status (readiness warnings) #:transparent)

(define (health-report storage #:now now)
  (unless (commerce-storage? storage)
    (raise-argument-error 'health-report "commerce-storage?" storage))
  (unless (exact-nonnegative-integer? now)
    (raise-argument-error 'health-report "exact-nonnegative-integer?" now))
  (define snapshot (storage-readiness storage #:now now))
  (define warnings
    (append
     (let ([blocked (readiness-projection-blocked snapshot)])
       (if (> blocked 0)
           (list (health-warning
                  'projection-blocked
                  (hash 'count blocked)))
           '()))
     (let ([stale (readiness-work-stale-lease snapshot)])
       (if (> stale 0)
           (list (health-warning
                  'issuance-lease-expired
                  (hash 'count stale)))
           '()))
     (let ([passed (readiness-claim-window-passed snapshot)])
       (if (> passed 0)
           (list (health-warning
                  'claim-window-passed
                  (hash 'count passed)))
           '()))))
  (health-status snapshot warnings))

;; Operator-visible logging of the current warnings, so a scheduled health
;; check leaves the same evidence a human would read.
(define (health-report! storage #:now now)
  (define report (health-report storage #:now now))
  (for ([warning (in-list (health-status-warnings report))])
    (log-commerce-event!
     'warning (health-warning-code warning)
     (hash)
     (health-warning-detail warning)))
  report)
