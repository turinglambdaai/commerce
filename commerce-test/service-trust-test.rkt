#lang racket/base

(require rackunit
         racket/file
         permit/issuer
         permit/trust
         json)

;; The deployment must read the issuer trust store via Permit's strict reader,
;; rather than first parsing with json/read-json (which may discard duplicates).
(test-case "issuer trust store refuses duplicate critical members"
  (define raw
    #"{\"protocol\":\"permit-trust-store\",\"protocol\":\"other\",\"version\":1,\"issuer\":\"example.test\",\"keys\":{}}")
  (check-exn exn:fail?
             (lambda () (read-trust-store (open-input-bytes raw)))))

(test-case "issuer trust store loads a valid generated key file"
  (define-values (_private public) (generate-ed25519-keypair))
  (define file (make-temporary-file "commerce-trust-~a.json"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file file
        (lambda (out)
          (write-json
           (hasheq 'protocol "permit-trust-store"
                   'version 1
                   'issuer "example.test"
                   'keys
                   (hasheq 'key-2026
                           (hasheq 'algorithm "Ed25519"
                                   'public_key (public-key->base64 public)
                                   'status "active"
                                   'purposes '("entitlement")
                                   'not_before 'null
                                   'not_after 'null)))
           out))
        #:exists 'truncate)
      (define store (read-trust-store file))
      (check-equal? (trust-store-issuer store) "example.test")
      (check-true (trust-key? (trust-store-key store "key-2026"))))
    (lambda () (delete-file file))))
