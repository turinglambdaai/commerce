#lang racket/base

(provide
 (struct-out journal-record)
 (struct-out journal-acceptance))

;; A record is the exact durable input plus the canonical meaning established
;; by the provider adapter at acceptance time.
(struct journal-record (sequence event payload received-at) #:transparent)

;; disposition is either 'accepted for a new durable row or 'replayed for an
;; exact retry that resolved to the original row.
(struct journal-acceptance (disposition record) #:transparent)
