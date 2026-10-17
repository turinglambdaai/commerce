#lang info

(define collection 'multi)
(define deps
  '(["base" #:version "9.0"]
    "base64-lib"
    "crypto-lib"
    "db-lib"
    "http-easy-lib"
    ["permit" #:version "0.1"]))
(define build-deps '("rackunit-lib" "racket-doc" "scribble-lib"))
(define pkg-desc
  "Provider-neutral commerce orchestration for independent software")
(define version "0.1")
(define pkg-authors '(turinglambdaai))
(define license 'Apache-2.0)

