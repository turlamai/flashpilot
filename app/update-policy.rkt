#lang racket/base

;; FlashPilot currently ships standalone CLI ZIPs, not desktop installers.
;; This is the *offline* trust/selection boundary for a future explicit
;; flashpilot update check command. It never makes a network request,
;; downloads an executable, touches an ECU, or replaces the running binary.
;; Production hosts must supply their *embedded*, pinned public key and
;; key ID; they must never trust a public key advertised by a remote feed.

(require racket/string
         rivet/distribution)

(provide flashpilot-update-application-id
         flashpilot-update-manifest-byte-limit
         flashpilot-update-artifact-byte-limit
         preview-signed-cli-update)

(define flashpilot-update-application-id "site.jrtx.flashpilot")
(define flashpilot-update-manifest-byte-limit (* 1024 1024))
(define flashpilot-update-artifact-byte-limit (* 512 1024 1024))

(define (preview-signed-cli-update signed-bytes
                                   #:user-initiated? user-initiated?
                                   #:trusted-public-key trusted-public-key
                                   #:expected-key-id expected-key-id
                                   #:current-version current-version
                                   #:platform [platform (platform-symbol)]
                                   #:architecture [architecture (architecture-symbol)])
  (unless user-initiated?
    (raise-arguments-error
     'preview-signed-cli-update
     "FlashPilot must only check for updates on explicit user or agent request"))
  (unless (and (string? expected-key-id)
               (not (string=? expected-key-id "")))
    (raise-arguments-error 'preview-signed-cli-update
                           "an embedded update signing key ID is required"))
  (unless (bytes? signed-bytes)
    (raise-argument-error 'preview-signed-cli-update "bytes?" signed-bytes))
  (when (> (bytes-length signed-bytes) flashpilot-update-manifest-byte-limit)
    (raise-arguments-error 'preview-signed-cli-update
                           "signed update metadata exceeds byte limit"
                           "bytes" (bytes-length signed-bytes)))
  ;; Authentication occurs BEFORE relying on any data from the payload.
  (define verified
    (verify-signed-manifest (open-input-bytes signed-bytes)
                            trusted-public-key
                            #:key-id expected-key-id))
  (define config
    (updater-config flashpilot-update-application-id current-version
                    'stable platform architecture trusted-public-key
                    expected-key-id 0 flashpilot-update-artifact-byte-limit 'cli))
  (define selected (select-update config verified #:install-kind 'portable))
  (when selected
    (define artifact (update-candidate-artifact selected))
    (define version (update-manifest-version verified))
    (define expected-name
      (format "flashpilot-~a-~a-~a.zip" version platform architecture))
    (define expected-url
      (format "https://github.com/turlamai/flashpilot/releases/download/v~a/~a"
              version expected-name))
    ;; Enforce exact immutable release/asset identity. No latest aliases,
    ;; redirect targets, URLs with queries or fragments, nor sibling files.
    (unless (and (eq? (update-artifact-component artifact) 'cli)
                 (eq? (update-artifact-installer artifact) 'zip)
                 (string=? (update-artifact-url artifact) expected-url))
      (raise-arguments-error 'preview-signed-cli-update
                             "signed CLI ZIP must use its exact official release URL"
                             "url" (update-artifact-url artifact)
                             "expected" expected-url))
    (when (> (update-artifact-size artifact)
             flashpilot-update-artifact-byte-limit)
      (raise-arguments-error 'preview-signed-cli-update
                             "signed CLI ZIP exceeds maximum download bytes"
                             "size" (update-artifact-size artifact))))
  ;; No caller is authorized to download or install as a consequence of
  ;; previewing: an additional explicit action, a bounded Rivet download,
  ;; and platform-aware upgrade handoff are separate required steps.
  selected)
