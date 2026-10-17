#lang racket/base

(provide
 (struct-out commerce-storage)
 (struct-out projection-result)
 (struct-out issuance-outbox-item))

;; One opaque service-storage handle owns journal, projection, and outbox
;; operations so the SQLite backend can enforce their transaction boundaries.
(struct commerce-storage
  (journal-accept journal-lookup project-next order-lookup outbox-lookup close)
  #:transparent)

;; disposition is 'projected or 'blocked. No pending journal row is represented
;; by #f, so callers cannot confuse idle work with a committed transition.
(struct projection-result
  (disposition journal-sequence order outbox failure-code)
  #:transparent)

;; Workflow fields are present now so emitted rows have a stable lease shape;
;; this slice only inserts pending work and does not expose worker mutations.
(struct issuance-outbox-item
  (id idempotency-key source-sequence action provider order-id offer-id
      subject-id occurred-at status attempts available-at lease-owner
      lease-expires-at last-error-code created-at updated-at completed-at)
  #:transparent)
