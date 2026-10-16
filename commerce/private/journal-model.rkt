#lang racket/base

(provide
 (struct-out event-journal)
 (struct-out journal-record)
 (struct-out journal-acceptance))

;; The constructor is private to persistence backends. Public callers interact
;; through commerce/journal so every backend shares the same validation path.
(struct event-journal (accept lookup close) #:transparent)

;; A record is the exact durable input plus the canonical meaning established
;; by the provider adapter at acceptance time.
(struct journal-record (sequence event payload received-at) #:transparent)

;; disposition is either 'accepted for a new durable row or 'replayed for an
;; exact retry that resolved to the original row.
(struct journal-acceptance (disposition record) #:transparent)
