#lang racket/base

;; Synthetic signing keys only: offline signed-release and attacker-negative
;; tests. No GitHub access, ECU, installed binary, or release secret is needed.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         rackunit
         rivet/distribution
         "../app/update-policy.rkt")

(crypto-factories (list libcrypto-factory))
(define signer (generate-private-key 'eddsa '((curve ed25519))))
(define wrong-signer (generate-private-key 'eddsa '((curve ed25519))))
(define pub (datum->pk-key (pk-key->datum signer 'rkt-public) 'rkt-public))
(define key-id "flashpilot-test-2026")
(define canonical-url
  "https://github.com/turlamai/flashpilot/releases/download/v0.2.0/flashpilot-0.2.0-linux-x64.zip")
(define cli-asset
  (update-artifact 'linux 'x64 canonical-url (make-string 64 #\a)
                   100000 'zip '() 'cli))
(define feed
  (update-manifest flashpilot-update-application-id "0.2.0" 2 'stable
                   "2026-11-01T00:00:00Z" "0.0.0"
                   #f #t 100 (list cli-asset)))
(define (signed manifest [key signer] [id key-id])
  (define out (open-output-bytes))
  (write-signed-manifest manifest key id out)
  (get-output-bytes out))
(define real-feed (signed feed))
(define (preview payload
                 #:consent? [consent? #t]
                 #:version [version "0.1.0"]
                 #:key-id [expected-key-id key-id]
                 #:platform [platform 'linux]
                 #:arch [arch 'x64])
  (preview-signed-cli-update
   payload #:user-initiated? consent?
   #:trusted-public-key pub #:expected-key-id expected-key-id
   #:current-version version #:platform platform #:architecture arch))

(check-exn #rx"explicit user or agent request"
           (lambda () (preview real-feed #:consent? #f)))
(check-exn #rx"embedded update signing key ID"
           (lambda () (preview real-feed #:key-id "")))
(check-exn #rx"metadata exceeds byte limit"
           (lambda ()
             (preview (make-bytes (add1 flashpilot-update-manifest-byte-limit) 42))))
(define candidate (preview real-feed))
(check-true (update-candidate? candidate))
(check-equal? (update-artifact-component
               (update-candidate-artifact candidate)) 'cli)
(check-equal? (update-artifact-url
               (update-candidate-artifact candidate)) canonical-url)

;; Already current, downgrade, wrong OS or CPU cannot trigger an update.
(check-false (preview real-feed #:version "0.2.0"))
(check-false (preview real-feed #:version "0.3.0"))
(check-false (preview real-feed #:platform 'windows))
(check-false (preview real-feed #:arch 'arm64))
(check-exn #rx"signature verification failed"
           (lambda () (preview (signed feed wrong-signer))))
(check-exn #rx"unexpected key"
           (lambda () (preview (signed feed signer "attacker-key"))))
(check-exn #rx"application identity mismatch"
           (lambda ()
             (preview (signed (struct-copy update-manifest feed
                                [application-id "site.jrtx.another"])))) )

;; Even a validly signed feed cannot substitute a moving release alias,
;; foreign GitHub owner, wrong archive, or query/fragment-bearing path.
(for ([url (in-list
            (list
             "https://github.com/turlamai/flashpilot/releases/latest/download/flashpilot-linux-x64.zip"
             "https://github.com/other/flashpilot/releases/download/v0.2.0/flashpilot-0.2.0-linux-x64.zip"
             "https://github.com/turlamai/flashpilot/releases/download/v0.2.0/flashpilot-0.2.0-linux-x64.exe"
             (string-append canonical-url "?download=1")
             (string-append canonical-url "#fragment")))])
  (define altered
    (struct-copy update-manifest feed
      [artifacts (list (struct-copy update-artifact cli-asset [url url]))]))
  (check-exn #rx"exact official release URL"
             (lambda () (preview (signed altered)))))

;; Signed app payloads are not CLI updates, and no unsigned sidecar is
;; permitted to stand in for the real ZIP's signed hash and exact size.
(check-false
 (preview (signed (struct-copy update-manifest feed
                    [artifacts (list (struct-copy update-artifact cli-asset
                                        [component 'app]))]))))
(check-exn #rx"maximum download bytes"
           (lambda ()
             (preview (signed (struct-copy update-manifest feed
                                [artifacts
                                 (list (struct-copy update-artifact cli-asset
                                        [size (add1 flashpilot-update-artifact-byte-limit)]))])))))

(displayln "FlashPilot signed CLI update preview tests passed")
