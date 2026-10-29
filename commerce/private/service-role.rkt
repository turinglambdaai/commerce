#lang racket/base

(provide parse-service-role
         service-role-edge?
         service-role-issuer?)

;; 'all is retained for local walkthroughs. Split edge and issuer roles
;; require separate OS users and a shared SQLite store in deployment.
(define (service-role? value)
  (memq value '(all edge issuer)))

(define (parse-service-role value)
  (cond
    [(equal? value "all") 'all]
    [(equal? value "edge") 'edge]
    [(equal? value "issuer") 'issuer]
    [else
     (raise-argument-error
      'parse-service-role
      "(or/c \"all\" \"edge\" \"issuer\")"
      value)]))

(define (service-role-edge? role)
  (unless (service-role? role)
    (raise-argument-error 'service-role-edge?
                          "(or/c 'all 'edge 'issuer)" role))
  (or (eq? role 'all) (eq? role 'edge)))

(define (service-role-issuer? role)
  (unless (service-role? role)
    (raise-argument-error 'service-role-issuer?
                          "(or/c 'all 'edge 'issuer)" role))
  (or (eq? role 'all) (eq? role 'issuer)))
