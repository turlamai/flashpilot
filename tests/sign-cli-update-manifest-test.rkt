#lang racket/base

;; Offline publisher tests. All keys and CLI ZIP fixtures are disposable;
;; release credentials, network APIs and actual installations are untouched.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         rackunit
         racket/file
         racket/path
         rivet/distribution
         "../scripts/sign-cli-update-manifest.rkt")

(crypto-factories (list libcrypto-factory))
(define secret (generate-private-key 'eddsa '((curve ed25519))))
(define wrong (generate-private-key 'eddsa '((curve ed25519))))
(define root (make-temporary-file "flashpilot-update-signing-~a" 'directory))
(define dist (build-path root "dist"))
(define private-file (build-path root "signing-private.der"))
(define public-file (build-path root "embedded-public.der"))
(define wrong-public-file (build-path root "wrong-public.der"))
(define output (build-path dist "update-manifest.json"))
(define version "0.2.0")
(define targets
  '((windows x64) (linux x64) (linux arm64) (macos x64) (macos arm64)))

(define (write-key path key format)
  (call-with-output-file path
    (lambda (out) (write-bytes (pk-key->datum key format) out))))

(define (sign!)
  (sign-cli-update-manifest!
   version 2 dist private-file public-file "flashpilot-2026"
   #:output output
   #:published-at "2026-11-01T00:00:00Z"))

(dynamic-wind
  void
  (lambda ()
    (make-directory dist)
    (write-key private-file secret 'PrivateKeyInfo)
    (write-key public-file secret 'SubjectPublicKeyInfo)
    (write-key wrong-public-file wrong 'SubjectPublicKeyInfo)
    (for ([target (in-list targets)] [index (in-naturals 1)])
      (define name
        (format "flashpilot-~a-~a-~a.zip"
                version (first target) (second target)))
      (call-with-output-file (build-path dist name)
        (lambda (out) (write-bytes (make-bytes (+ 128 index) index) out))))
    (check-equal? (sign!) output)
    (define verified
      (call-with-input-file output
        (lambda (in)
          (verify-signed-manifest in
                                  (read-ed25519-public-key public-file)
                                  #:key-id "flashpilot-2026"))))
    (check-equal? (update-manifest-application-id verified)
                  "site.jrtx.flashpilot")
    (check-equal? (update-manifest-version verified) "0.2.0")
    (check-equal? (update-manifest-channel verified) 'stable)
    (check-equal? (length (update-manifest-artifacts verified)) 5)
    (for ([artifact (in-list (update-manifest-artifacts verified))])
      (define name
        (format "flashpilot-~a-~a-~a.zip" version
                (update-artifact-platform artifact)
                (update-artifact-architecture artifact)))
      (define file (build-path dist name))
      (check-equal? (update-artifact-component artifact) 'cli)
      (check-equal? (update-artifact-installer artifact) 'zip)
      (check-equal? (update-artifact-url artifact)
                    (string-append
                     "https://github.com/turlamai/flashpilot/releases/download/v0.2.0/"
                     name))
      (check-equal? (update-artifact-sha256 artifact)
                    (sha256-file/hex file))
      (check-equal? (update-artifact-size artifact) (file-size file)))
    (define known-good (file->bytes output))

    ;; Fail-closed publisher: a wrong trust root must not replace an
    ;; already verified manifest, even if the signing key itself is valid.
    (check-exn #rx"signature verification failed"
               (lambda ()
                 (sign-cli-update-manifest!
                  version 2 dist private-file wrong-public-file
                  "flashpilot-2026" #:output output)))
    (check-equal? (file->bytes output) known-good)

    ;; A missing architecture invalidates the whole five-asset release.
    (define absent
      (build-path dist "flashpilot-0.2.0-macos-arm64.zip"))
    (delete-file absent)
    (check-exn #rx"required CLI release archive"
               (lambda () (sign!)))
    (check-equal? (file->bytes output) known-good)

    (check-exn #rx"missing required option"
               (lambda () (parse-sign-cli-update-arguments '())))
    (define arguments
      (parse-sign-cli-update-arguments
       (list "--version" version "--build" "2" "--dir" "dist"
             "--private-key" "private.der" "--public-key" "public.der"
             "--key-id" "flashpilot-2026")))
    (check-equal? (hash-ref arguments 'build) 2)
    (check-exn #rx"positive integer"
               (lambda ()
                 (parse-sign-cli-update-arguments
                  (list "--version" version "--build" "0" "--dir" "dist"
                        "--private-key" "private.der" "--public-key" "public.der"
                        "--key-id" "flashpilot-2026")))))
  (lambda () (delete-directory/files root #:must-exist? #f)))

(displayln "FlashPilot signed CLI release manifest tests passed")
