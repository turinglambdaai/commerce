#lang racket/base

;; The UTC derivation behind every issued timestamp. The anchors are
;; precomputed UTC facts (leap day, epoch, the gptp-studio exemplar's
;; window boundary, century edges) so a regression back to host-local
;; wall clock fails on any machine east or west of UTC.

(require commerce/private/time
         rackunit)

(test-case "epoch anchors render as UTC, never host-local wall clock"
  (define anchors
    (list (cons 0 "1970-01-01T00:00:00Z")
          (cons 951782400 "2000-02-29T00:00:00Z")
          (cons 1792108800 "2026-10-16T00:00:00Z")
          (cons 1823644800 "2027-10-16T00:00:00Z")
          (cons 2534023007 "2050-04-19T23:16:47Z")
          (cons 4102444799 "2099-12-31T23:59:59Z")))
  (for ([anchor (in-list anchors)])
    (check-equal? (epoch-seconds->rfc3339 (car anchor)) (cdr anchor)
                  (format "epoch ~a" (car anchor)))))

(test-case "sub-second fields stay exact"
  (check-equal? (epoch-seconds->rfc3339 86399) "1970-01-01T23:59:59Z")
  (check-equal? (epoch-seconds->rfc3339 86400) "1970-01-02T00:00:00Z"))

(test-case "negative and non-integer seconds are refused"
  (check-exn exn:fail:contract? (lambda () (epoch-seconds->rfc3339 -1)))
  (check-exn exn:fail:contract? (lambda () (epoch-seconds->rfc3339 1.5)))
  (check-exn exn:fail:contract? (lambda () (epoch-seconds->rfc3339 "0"))))
