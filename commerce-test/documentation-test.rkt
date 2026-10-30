#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root/raw "..")
(define repository-root (simplify-path repository-root/raw #t))

(define (markdown-file? path)
  (and (file-exists? path)
       (equal? (path-get-extension path) #".md")))

(define markdown-files
  (append
   (filter markdown-file?
           (directory-list repository-root #:build? #t))
   (find-files markdown-file? (build-path repository-root "docs"))))

(define markdown-link-pattern #px"\\[[^]]*\\]\\(([^)]+)\\)")
(define external-link-pattern #px"^(?:https?://|mailto:|#)")

(define (strip-fragment target)
  (car (string-split target "#" #:trim? #f)))

(for* ([document (in-list markdown-files)]
       [match (in-list
               (regexp-match* markdown-link-pattern
                              (file->string document)
                              #:match-select values))])
  (define target (cadr match))
  (unless (regexp-match? external-link-pattern target)
    (define local-target (strip-fragment target))
    (unless (string=? local-target "")
      (define resolved
        (simplify-path (build-path (path-only document) local-target) #f))
      (check-true
       (or (file-exists? resolved) (directory-exists? resolved))
       (format "~a links to missing local target ~a"
               (find-relative-path repository-root document)
               target)))))

(define canonical-family-url
  "https://github.com/turlamai/keel/blob/main/docs/family-architecture.md")

(for ([entry '("AGENTS.md"
               "README.md"
               "README.zh-CN.md"
               "docs/architecture.md"
               "docs/family-integration.md")])
  (check-true
   (string-contains? (file->string (build-path repository-root entry))
                     canonical-family-url)
   (format "~a must link the canonical family architecture" entry)))

;; A repository handling payments and signing must expose an unambiguous
;; confidential reporting path, a reproducible PR handoff, and a release gate
;; which does not equate fixture CI with live merchant approval.
(for ([entry '("SECURITY.md"
               ".github/PULL_REQUEST_TEMPLATE.md"
               "docs/release-checklist.md")])
  (check-true
   (file-exists? (build-path repository-root entry))
   (format "missing security/release governance entry ~a" entry)))

(for ([entry '("AGENTS.md" "README.md" "README.zh-CN.md" "ROADMAP.md")])
  (check-true
   (string-contains? (file->string (build-path repository-root entry))
                     "docs/release-checklist.md")
   (format "~a must identify the verifiable release gates" entry)))

(for ([entry '("AGENTS.md" "README.md" "README.zh-CN.md" "CONTRIBUTING.md")])
  (check-true
   (string-contains? (file->string (build-path repository-root entry))
                     "SECURITY.md")
   (format "~a must link confidential security reporting" entry)))

(check-true
 (string-contains? (file->string
                    (build-path repository-root "docs/README.md"))
                   "release-checklist.md")
 "documentation map must link the release evidence checklist")

(check-true
 (string-contains? (file->string
                    (build-path repository-root "CONTRIBUTING.md"))
                   ".github/PULL_REQUEST_TEMPLATE.md")
 "contribution instructions must link the PR handoff template")
