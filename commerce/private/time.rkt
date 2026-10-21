#lang racket/base

;; RFC 3339 UTC timestamps from epoch seconds, independent of the host
;; time zone. Racket's seconds->date is local wall-clock in every release
;; this family runs — the positional boolean is leap-second precision,
;; not a UTC flag — so the civil conversion is derived from the day count
;; directly. A replayed order must converge on the same window bytes on
;; any host: a UTC+8 machine wrote paid-through windows and issued_at
;; eight hours early while CI, running in UTC, could never see it.

(provide epoch-seconds->rfc3339)

;; Days since 1970-01-01 to a proleptic-Gregorian year/month/day
;; (Hinnant's civil_from_days). The era guard keeps the floor divisions
;; exact if a negative second ever reaches this module.
(define (civil-from-days days)
  (define z (+ days 719468))
  (define era (quotient (if (>= z 0) z (- z 146096)) 146097))
  (define doe (- z (* era 146097)))
  (define yoe
    (quotient (+ (- doe (quotient doe 1460))
                 (quotient doe 36524)
                 (- (quotient doe 146096)))
              365))
  (define y (+ yoe (* era 400)))
  (define doy
    (- doe (+ (* 365 yoe) (quotient yoe 4) (- (quotient yoe 100)))))
  (define mp (quotient (+ (* 5 doy) 2) 153))
  (define day (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
  (define month (if (< mp 10) (+ mp 3) (- mp 9)))
  (values (if (<= month 2) (+ y 1) y) month day))

(define (epoch-seconds->rfc3339 epoch-seconds)
  (unless (and (exact-integer? epoch-seconds) (>= epoch-seconds 0))
    (raise-argument-error
     'epoch-seconds->rfc3339 "exact-nonnegative-integer?" epoch-seconds))
  (define seconds-of-day (modulo epoch-seconds 86400))
  (define-values (year month day)
    (civil-from-days (quotient epoch-seconds 86400)))
  (string-append
   (pad-number year 4) "-"
   (pad-number month 2) "-"
   (pad-number day 2) "T"
   (pad-number (quotient seconds-of-day 3600) 2) ":"
   (pad-number (quotient (modulo seconds-of-day 3600) 60) 2) ":"
   (pad-number (modulo seconds-of-day 60) 2) "Z"))

(define (pad-number value width)
  (define digits (number->string value))
  (if (< (string-length digits) width)
      (string-append (make-string (- width (string-length digits)) #\0)
                     digits)
      digits))
