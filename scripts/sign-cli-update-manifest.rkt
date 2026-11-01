#lang racket/base

;; Offline publisher: signs the exact five standalone FlashPilot CLI archives.
;; Intentionally NOT wired into the live release job until production release
;; keys and the installed CLI's pinned public trust root have been provisioned.
;; No private signing key is stored here or printed to logs.

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         rivet/distribution)

(provide sign-cli-update-manifest!
         parse-sign-cli-update-arguments)

(define cli-targets
  '((windows x64) (linux x64) (linux arm64)
    (macos x64) (macos arm64)))

(define (expected-asset-name version platform arch)
  (format "flashpilot-~a-~a-~a.zip" version platform arch))

(define (sign-cli-update-manifest!
         version build dist-dir signing-key-path trusted-public-key-path key-id
         #:output [output (build-path dist-dir "update-manifest.json")]
         #:published-at [published-at (rfc3339-now)]
         #:minimum-version [minimum-version "0.0.0"])
  (unless (version? version)
    (raise-argument-error 'sign-cli-update-manifest!
                          "valid SemVer 2.0 string" version))
  (unless (exact-positive-integer? build)
    (raise-argument-error 'sign-cli-update-manifest!
                          "exact-positive-integer?" build))
  (unless (and (string? key-id) (not (string=? key-id "")))
    (raise-argument-error 'sign-cli-update-manifest!
                          "nonempty signing key ID" key-id))
  (unless (directory-exists? dist-dir)
    (raise-arguments-error 'sign-cli-update-manifest!
                           "release asset directory is missing"
                           "path" dist-dir))
  (define base-url
    (format "https://github.com/turlamai/flashpilot/releases/download/v~a"
            version))
  (define artifacts
    (for/list ([target (in-list cli-targets)])
      (match-define (list platform arch) target)
      (define name (expected-asset-name version platform arch))
      (define path (build-path dist-dir name))
      (unless (and (file-exists? path) (not (link-exists? path)))
        (raise-arguments-error
         'sign-cli-update-manifest!
         "required CLI release archive is missing or a symlink"
         "archive" name "path" path))
      (unless (positive? (file-size path))
        (raise-arguments-error
         'sign-cli-update-manifest! "CLI release archive is empty"
         "archive" name))
      (update-artifact
       platform arch
       (string-append base-url "/" name)
       (sha256-file/hex path) (file-size path)
       'zip '() 'cli)))
  (define signed
    (update-manifest
     "site.jrtx.flashpilot" version build 'stable
     published-at minimum-version #f #f 100 artifacts))
  (define secret (read-ed25519-private-key signing-key-path))
  (define public (read-ed25519-public-key trusted-public-key-path))
  (make-parent-directory* output)
  (define temporary
    (make-temporary-file "flashpilot-update-~a.json" #f
                         (or (path-only output) (current-directory))))
  (with-handlers ([exn?
                   (lambda (error)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise error))])
    (call-with-output-file temporary #:exists 'truncate/replace
      (lambda (out)
        (write-signed-manifest signed secret key-id out)))
    ;; Fail closed if the private signer and public key pinned in installed
    ;; clients are inconsistent; the target manifest is never overwritten.
    (define checked
      (call-with-input-file temporary
        (lambda (in)
          (verify-signed-manifest in public #:key-id key-id))))
    (unless (and (equal? (update-manifest-application-id checked)
                         "site.jrtx.flashpilot")
                 (= (length (update-manifest-artifacts checked))
                    (length cli-targets)))
      (error 'sign-cli-update-manifest!
             "signed CLI release manifest did not round-trip"))
    (rename-file-or-directory temporary output #t))
  output)

(define (parse-sign-cli-update-arguments argv)
  (let loop ([args argv] [opts (hasheq)])
    (match args
      ['()
       (for ([field '(version build dir private-key public-key key-id)])
         (unless (hash-has-key? opts field)
           (raise-arguments-error
            'sign-cli-update-manifest "missing required option"
            "option" field)))
       (define raw-build (hash-ref opts 'build))
       (define n (string->number raw-build))
       (unless (exact-positive-integer? n)
         (raise-arguments-error 'sign-cli-update-manifest
                                "--build must be a positive integer"
                                "value" raw-build))
       (hash-set opts 'build n)]
      [(list* (and flag (or "--version" "--build" "--dir"
                             "--private-key" "--public-key"
                             "--key-id" "--output")) value tail)
       (define field (string->symbol (substring flag 2)))
       (when (hash-has-key? opts field)
         (raise-arguments-error 'sign-cli-update-manifest
                                "duplicate option" "option" flag))
       (loop tail (hash-set opts field value))]
      [(cons unknown _)
       (raise-arguments-error 'sign-cli-update-manifest
                              "invalid or incomplete option"
                              "option" unknown)])))

(module+ main
  (define args
    (parse-sign-cli-update-arguments
     (vector->list (current-command-line-arguments))))
  (define output
    (sign-cli-update-manifest!
     (hash-ref args 'version)
     (hash-ref args 'build)
     (hash-ref args 'dir)
     (hash-ref args 'private-key)
     (hash-ref args 'public-key)
     (hash-ref args 'key-id)
     #:output (hash-ref args 'output
                        (build-path (hash-ref args 'dir)
                                    "update-manifest.json"))))
  (printf "Signed and verified CLI update manifest: ~a\n" output))
