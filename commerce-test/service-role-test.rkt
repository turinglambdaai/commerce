#lang racket/base

(require rackunit
         commerce/private/service-role)

(test-case "role selections are explicit, with local combined mode"
  (check-eq? (parse-service-role "all") 'all)
  (check-eq? (parse-service-role "edge") 'edge)
  (check-eq? (parse-service-role "issuer") 'issuer)
  (for ([role (in-list '(all edge issuer))])
    (check-equal? (service-role-edge? role)
                  (if (memq role '(all edge)) #t #f)
                  "Only the edge/combined process may open a public listener")
    (check-equal? (service-role-issuer? role)
                  (if (memq role '(all issuer)) #t #f)
                  "Only the issuer/combined process may load the Permit key")))

(test-case "invalid role names and data fail before opening secrets"
  (for ([v (in-list (list "" "production" "EDGE" "worker" #f 1))])
    (check-exn exn:fail?
               (lambda () (parse-service-role v))))
  (check-exn exn:fail? (lambda () (service-role-edge? 'bad)))
  (check-exn exn:fail? (lambda () (service-role-issuer? 'bad))))
