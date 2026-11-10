#lang racket/base

;; CLI identity contract: `--version` / `-v` / `version` print exactly one
;; JSON object on stdout and exit 0 — no channel, no device, no network.
;; The test spawns the real CLI as a subprocess (the same file CI compiles),
;; so it pins the argv contract, not an in-process function. The expected
;; version is read from VERSION — the same truth source
;; scripts/check-release-version.sh enforces across CHANGELOG, rivet.rktd,
;; racket/info.rkt, app/backend.rkt and app/cli.rkt.

(require json
         racket/file
         (only-in racket/system system*/exit-code)
         racket/port
         racket/runtime-path
         racket/string
         rackunit)

(define-runtime-path repo-root "../")
(define cli-path (path->string (build-path repo-root "app" "cli.rkt")))
(define expected-version
  (string-trim (file->string (build-path repo-root "VERSION"))))

(define (run-cli argv)
  (define out (open-output-string))
  (parameterize ([current-output-port out])
    (define code
      (apply system*/exit-code (find-system-path 'exec-file) cli-path argv))
    (values (get-output-string out) code)))

(define (check-identity argv)
  (define-values (out code) (run-cli argv))
  (check-equal? code 0 (format "~a must exit 0" argv))
  (check-true (string-prefix? out "{") (format "~a must print one JSON object" argv))
  (define j (read-json (open-input-string out)))
  (check-equal? (hash-ref j 'ok) #t (format "~a must report ok" argv))
  (check-equal? (hash-ref j 'version) expected-version
                (format "~a must report the VERSION file's version" argv))
  (check-equal? (hash-ref j 'product) "FlashPilot"))

(check-identity '("--version"))
(check-identity '("-v"))
(check-identity '("version"))
