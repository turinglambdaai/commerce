#lang racket/base

(provide
 (struct-out commerce-storage)
 (struct-out projection-result)
 (struct-out issuance-outbox-item)
 (struct-out entitlement-lineage)
 (struct-out entitlement-revision)
 (struct-out issuance-completion))

;; One opaque service-storage handle owns journal, projection, outbox, and
;; issuance operations so the SQLite backend can enforce their transaction
;; boundaries.
(struct commerce-storage
  (journal-accept journal-lookup project-next order-lookup outbox-lookup
                  issuance-claim issuance-complete issuance-release
                  entitlement-lookup lineage-lookup revision-lookup
                  latest-revision-lookup close)
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

;; The stable entitlement identity. credential_type is a schema constant
;; ('entitlement) because Commerce only maps Offers to Permit entitlement
;; credentials.
(struct entitlement-lineage
  (entitlement-id issuer subject-type subject-id offer-id created-at)
  #:transparent)

;; One append-only revision of unsigned Permit evidence. payload-bytes are the
;; exact unsigned snapshot bytes; they are never signed credential bytes.
(struct entitlement-revision
  (entitlement-id revision previous-revision credential-id issuance-outbox-id
                  action policy-id policy-version payload-bytes payload-digest
                  issued-at recorded-at)
  #:transparent)

;; Completion returns the finished work together with the revision it appended,
;; so a retry after an ambiguous crash reconciles instead of duplicating.
(struct issuance-completion (outbox revision) #:transparent)
