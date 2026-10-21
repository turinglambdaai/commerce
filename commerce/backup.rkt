#lang racket/base

(provide
 snapshot-commerce-database!
 verify-commerce-backup
 backup-verification?
 backup-verification-ok?
 backup-verification-details)

(require db
         "log.rkt"
         "storage.rkt"
         "storage/sqlite.rkt"
         "private/model.rkt"
         "private/storage-model.rkt")

;; Encrypted-at-rest handling (age, LUKS, cloud KMS) belongs to the
;; deployment. This boundary owns what Commerce itself can prove: one
;; consistent snapshot file, and a restore rehearsal that compares the
;; restored copy's readiness against the original at the same instant.

(struct backup-verification (ok? details) #:transparent)

;; Writes a consistent copy of the live database to destination-path using
;; SQLite's VACUUM INTO, which reads through one transaction snapshot and
;; refuses to overwrite. Works while the service is running.
(define (snapshot-commerce-database! database-path destination-path)
  (unless (path-string? database-path)
    (raise-argument-error
     'snapshot-commerce-database! "path-string?" database-path))
  (unless (path-string? destination-path)
    (raise-argument-error
     'snapshot-commerce-database! "path-string?" destination-path))
  (define connection
    (sqlite3-connect #:database database-path #:mode 'read-only))
  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (disconnect connection)
                     (raise failure))])
    (query-exec connection
                "VACUUM INTO ?" (path->string destination-path))
    (disconnect connection))
  destination-path)

;; Restore rehearsal: open the backup copy, verify Commerce's database
;; identity and integrity, and compare its readiness counts against the
;; original at the same instant. Any mismatch fails the rehearsal.
(define (verify-commerce-backup original-storage backup-path #:now now)
  (unless (commerce-storage? original-storage)
    (raise-argument-error
     'verify-commerce-backup "commerce-storage?" original-storage))
  (unless (path-string? backup-path)
    (raise-argument-error
     'verify-commerce-backup "path-string?" backup-path))
  (unless (exact-nonnegative-integer? now)
    (raise-argument-error
     'verify-commerce-backup "exact-nonnegative-integer?" now))
  (define original (storage-readiness original-storage #:now now))
  (define connection
    (sqlite3-connect #:database backup-path #:mode 'read-only))
  (define details
    (with-handlers ([exn:fail?
                     (lambda (_failure)
                       (disconnect connection)
                       (raise
                        (exn:fail:commerce
                         "backup verification could not open the copy"
                         (current-continuation-marks)
                         'backup-unreadable
                         (hash 'backup-path (path->string backup-path)))))])
      (define integrity
        (query-value connection "PRAGMA integrity_check"))
      (define application-id
        (query-value connection "PRAGMA application_id"))
      (define version
        (query-value connection "PRAGMA user_version"))
      (define restored
        (query-value
         connection "SELECT COUNT(*) FROM commerce_event_journal"))
      (disconnect connection)
      (hash 'integrity integrity
            'application-id application-id
            'schema-version version
            'journal-total restored
            'expected-journal-total
            (readiness-journal-total original))))
  (define ok?
    (and (equal? (hash-ref details 'integrity) "ok")
         (= (hash-ref details 'application-id) 1129270605)
         (= (hash-ref details 'schema-version)
            (readiness-schema-version original))
         (= (hash-ref details 'journal-total)
            (hash-ref details 'expected-journal-total))))
  (values (backup-verification ok? details) original))
