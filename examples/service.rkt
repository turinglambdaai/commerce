#lang racket/base

;; One deployable assembly of the commerce boundaries: the HTTP edge
;; (webhooks, claim portal, readiness), the projector, and the issuer
;; worker loop, over one SQLite store. Configuration comes from the
;; environment; secrets are injected as file paths, never committed.
;;
;; Run it only after reading docs/runbook.md and deploy/README.md. The
;; catalog below is a placeholder: replace it with your product's
;; reviewed, version-pinned policy before accepting real payments.
;;
;; Termination: SIGTERM/SIGKILL is crash-safe by design (WAL +
;; synchronous=FULL; a restart re-claims expired leases and re-projects
;; from the immutable journal). A clean shutdown posts the stop
;; semaphore and closes the store.

(module+ main
  (require commerce/health
           commerce/issuer
           commerce/pancake
           commerce/permit
           commerce/server
           commerce/storage
           commerce/storage/sqlite
           json
           permit/issuer
           racket/file
           racket/match
           racket/string)

  ;; ---- configuration -------------------------------------------------

  (define (env name [default #f])
    (define value (getenv name))
    (if (and value (not (string=? value ""))) value default))

  (define (env-require name)
    (or (env name)
        (begin
          (eprintf "missing required environment variable ~a\n" name)
          (exit 1))))

  (define (env-number name default)
    (define value (env name))
    (if value (string->number value) default))

  (define db-path (env-require "COMMERCE_DB_PATH"))
  (define port (env-number "COMMERCE_PORT" 8080))
  (define listen-ip (env "COMMERCE_LISTEN_IP" "127.0.0.1"))
  (define poll-seconds (env-number "COMMERCE_POLL_SECONDS" 2))
  (define issuer-name (env-require "COMMERCE_ISSUER"))
  (define key-id (env-require "PERMIT_KEY_ID"))
  (define private-key-path (env-require "PERMIT_PRIVATE_KEY_PATH"))
  (define trust-store-path (env-require "PERMIT_TRUST_STORE_PATH"))
  (define merchant-id (env-require "PANCAKE_MERCHANT_ID"))
  (define merchant-key-path (env-require "PANCAKE_MERCHANT_KEY_PATH"))
  (define webhook-test-key-path
    (env-require "PANCAKE_WEBHOOK_TEST_KEY_PATH"))
  (define webhook-production-key-path
    (env-require "PANCAKE_WEBHOOK_PRODUCTION_KEY_PATH"))
  (define environment
    (match (env "COMMERCE_ENVIRONMENT" "test")
      ["test" 'test]
      ["production" 'production]
      [other
       (eprintf "COMMERCE_ENVIRONMENT must be test or production, got ~a\n"
                other)
       (exit 1)]))

  ;; ---- trust and configuration ---------------------------------------

  (define private-key (read-ed25519-private-key private-key-path))
  (define trust-store
    (jsexpr->trust-store
     (with-input-from-file trust-store-path read-json)))

  ;; PLACEHOLDER catalog: replace with the product's reviewed,
  ;; version-pinned policies. Policy ids are immutable; a rights change
  ;; is a new policy id (docs/permit-integration.md).
  (define catalog
    (make-permit-policy-catalog
     (list (offer "taskly-pro-lifetime" "taskly" 'one-time
                  (money "USD" 2900) "taskly-pro-v1"))
     (list
      (make-permit-entitlement-policy
       "taskly-pro-v1" 1
       #:subject-type 'person
       #:grants
       (list (make-permit-grant-policy
              #:products '("taskly") #:edition "pro"))))))

  ;; ---- storage, worker, edge ------------------------------------------

  (define storage (open-sqlite-commerce-storage db-path))

  (define worker
    (make-issuance-worker
     #:catalog catalog
     #:issuer issuer-name
     #:private-key private-key
     #:key-id key-id
     #:trust-store trust-store
     #:owner (env "COMMERCE_WORKER_OWNER" "commerce-service")))

  (define merchant-client
    (make-pancake-merchant-client
     merchant-id
     (file->string merchant-key-path)
     #:environment environment))

  (define endpoint
    (make-webhook-endpoint
     #:keyring
     (pancake-webhook-keyring
      (string-trim (file->string webhook-test-key-path))
      (string-trim (file->string webhook-production-key-path)))
     #:environment environment
     #:merchant-client merchant-client
     #:binding-lookup
     (lambda (order-id)
       (storage-checkout-binding-ref storage order-id))
     #:storage storage))

  ;; ---- worker loop: project everything, then issue one, repeat -------

  (define stop (make-semaphore))

  (define worker-thread
    (thread
     (lambda ()
       (let loop ()
         (define fired (sync/timeout poll-seconds stop))
         (unless fired
           (with-handlers
               ([exn:fail:commerce?
                 ;; Release/backoff already recorded the failure on the
                 ;; outbox row; the next pass retries within its bounds.
                 (lambda (_failure) (void))]
                [exn:fail?
                 (lambda (_failure) (void))])
             (let project ()
               (when (storage-project-next! storage
                                            #:processed-at
                                            (current-seconds))
                 (project)))
             (process-issuance-work! worker storage))
           (loop))))))

  ;; ---- serve ----------------------------------------------------------

  (define http-stop
    (serve-webhook-endpoint endpoint
                            #:port port
                            #:listen-ip listen-ip))

  (printf "commerce service: db=~a port=~a environment=~a\n"
          db-path port environment)
  (flush-output)

  ;; Block forever. SIGTERM/SIGKILL ends the process; the durable design
  ;; recovers on restart. For a clean in-process shutdown, post `stop`.
  (sync stop)
  (http-stop)
  (kill-thread worker-thread)
  (storage-close storage)
  (displayln "commerce service: stopped")))
