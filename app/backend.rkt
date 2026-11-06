#lang racket/base

;; FlashPilot Studio backend — the Racket domain core serving the native
;; shells. FlashPilot's value, on Rivet: one typed RPC surface
;; over the flashing engine, plans, readiness and evidence.

(require rivet/backend
         rivet/resources
         json
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string)

(require flashpilot/core/contracts
         flashpilot/diagnostics/channels/sim-uds-channel
         flashpilot/diagnostics/doip/doip
         flashpilot/diagnostics/flash/plans
         flashpilot/diagnostics/flash/validation
         flashpilot/diagnostics/uds/protocol)

(provide start)

(define-event plan-progress : String)
(define-state flash-count : Int64 0)

(define sim-channel (make-sim-uds-channel))

;; Read-only: the simulated bench identity + capability surface. Real
;; transports (DoIP/CAN) attach where this state is created today. `mode`
;; is the honest target label the native shells must render; `fixtures`
;; points at the simulator plans shipped inside the package (null when
;; running outside a packaged or staged app layout).
(define (bundled-fixtures-dir)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define dir (resource-path "examples"))
    (and (directory-exists? dir) (path->string dir))))

(define-rpc (bench-status : String)
  (jsexpr->string
   (hasheq 'product "FlashPilot"
           'version "0.1.0"
           'mode "simulator"
           'transport "sim-uds"
           'ecu "FlashPilot sim-ecu v1.0.4"
           'fixtures (or (bundled-fixtures-dir) 'null)
           'ready #t)))

;; Readiness: the plan-less preflight — transports configured, ECU alive.
(define-rpc (bench-validate : String)
  (define probe (sim-channel-request sim-channel (uds-read-dtcs #xFF) 1000 5000))
  (jsexpr->string
   (hasheq 'ok (uds-request-result-ok probe)
           'positive (uds-request-result-positive probe)
           'checks
           (list (hasheq 'code "transport.alive"
                         'passed (uds-request-result-ok probe)
                         'severity "error"
                         'summary "Simulated ECU answers UDS requests.")))))

;; Plan verification without ECU contact. Mirrors the CLI (`flashpilot
;; validate`/`verify`): segment files resolve relative to the plan's own
;; directory, structural lint runs on file-backed segments, and the
;; fingerprint gate is checked against expectedFingerprint. Every expected
;; failure returns a distinct recovery kind — plan-unreadable,
;; plan-invalid, segment-unavailable — instead of a cross-wire exception,
;; so shells can render honest recovery instead of a dead screen.
(struct exn:verify-abort exn:fail (kind message) #:transparent)

(define (verify-abort kind message)
  (raise (exn:verify-abort (format "~a: ~a" kind message)
                           (current-continuation-marks)
                           kind
                           message)))

(define (plan-base-directory plan-path)
  (path->string
   (path-only (simplify-path (path->complete-path plan-path)))))

(define (verify-plan-result plan-path)
  (define text
    (with-handlers ([exn:verify-abort? raise]
                    [exn:fail? (lambda (e)
                                 (verify-abort "plan-unreadable" (exn-message e)))])
      (file->string plan-path)))
  (define hardening
    (with-handlers ([exn:verify-abort? raise]
                    [exn:benchpilot:validation?
                     (lambda (e) (verify-abort "plan-invalid" (exn-message e)))])
      (read-flash-plan-json text)))
  (define plan (uds-flash-hardening-plan hardening))
  (define base-dir (plan-base-directory plan-path))
  (define loaded
    (for/list ([seg (in-list (uds-flash-plan-segments plan))])
      (if (and (uds-flash-segment-data seg) (not (null? (uds-flash-segment-data seg))))
          seg
          (with-handlers
              ([exn:verify-abort? raise]
               [exn:benchpilot:validation?
                (lambda (e)
                  (define message (exn-message e))
                  (if (string-prefix? message "Flash plan segment file not found")
                      (verify-abort "segment-unavailable" message)
                      (verify-abort "plan-invalid" message)))])
            (struct-copy uds-flash-segment seg
                         [data (bytes->list
                                (read-segment-file (uds-flash-segment-file seg)
                                                   base-dir))])))))
  (define plan* (struct-copy uds-flash-plan plan [segments loaded]))
  (define issues (plan-validation-issues plan*))
  (define blocking (plan-blocking-errors issues))
  (define fingerprint (flash-plan-fingerprint (uds-flash-plan-segments plan*)))
  (define expected (uds-flash-hardening-expected-fingerprint hardening))
  (define match (and expected (string-ci=? expected fingerprint)))
  (hasheq 'ok (and (null? blocking) (if expected match #t))
          'file plan-path
          'error 'null
          'findings (plan-issues->json issues)
          'segments (length loaded)
          'segmentDetails
          (for/list ([seg (in-list loaded)])
            (hasheq 'address (uds-flash-segment-address seg)
                    'bytes (length (uds-flash-segment-data seg))
                    'source (or (uds-flash-segment-file seg) "inline")))
          'session (or (uds-flash-plan-session plan) 'null)
          'securityLevel (or (uds-flash-plan-security-level plan) 'null)
          'dataLength (uds-flash-hardening-data-length hardening)
          'fingerprint fingerprint
          'expected (or expected 'null)
          'match (if expected match 'null)
          'onFail (or (let ([of (uds-flash-hardening-on-fail hardening)])
                        (and of (symbol->string of)))
                      'null)
          'powerGuard (if (uds-flash-hardening-power-guard hardening) 'configured 'null)))

(define-rpc (verify-plan [planPath String] : String)
  (with-handlers ([exn:verify-abort?
                   (lambda (e)
                     (jsexpr->string
                      (hasheq 'ok #f
                              'file planPath
                              'error (hasheq 'kind (exn:verify-abort-kind e)
                                             'message (exn:verify-abort-message e))
                              'findings '())))])
    (jsexpr->string (verify-plan-result planPath))))

;; DTC read against the attached ECU.
(define-rpc (dtc-read : String)
  (define result (sim-channel-request sim-channel (uds-read-dtcs #xFF) 1000 5000))
  (if (uds-request-result-positive result)
      (jsexpr->string (hasheq 'ok #t
                              'dtcs (parse-dtc-response
                                     (hex-parse (uds-request-result-response-hex result)))))
      (jsexpr->string (hasheq 'ok #f 'error "Negative response."))))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
