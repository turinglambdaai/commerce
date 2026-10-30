#lang racket/base

(provide parse-service-role
         service-role-edge?
         service-role-issuer?
         validate-service-role-environment!
         reject-demo-catalog-in-production!)

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

;; In production a combined HTTP and signing process defeats the split-key
;; boundary even if deployment secrets are otherwise file-injected. Fail
;; closed before reading any keys, opening SQLite or starting a listener.
(define (validate-service-role-environment! role environment)
  (unless (service-role? role)
    (raise-argument-error 'validate-service-role-environment!
                          "(or/c 'all 'edge 'issuer)" role))
  (unless (memq environment '(test production))
    (raise-argument-error 'validate-service-role-environment!
                          "(or/c 'test 'production)" environment))
  (when (and (eq? environment 'production) (eq? role 'all))
    (raise-arguments-error 'validate-service-role-environment!
                           "combined HTTP/issuer role is forbidden in production"
                           "role" role
                           "environment" environment))
  (void))

;; The bundled Taskly catalog is a fixture, not an admitted commercial offer.
;; A real product must replace this call with its reviewed product catalog
;; before production signing is enabled. Edge-only ingress can still boot.
(define (reject-demo-catalog-in-production! role environment)
  (validate-service-role-environment! role environment)
  (when (and (eq? environment 'production)
             (service-role-issuer? role))
    (raise-arguments-error 'reject-demo-catalog-in-production!
                           "bundled demo offer catalog cannot issue production rights"
                           "role" role
                           "environment" environment))
  (void))

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
