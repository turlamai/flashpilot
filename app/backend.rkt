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
         flashpilot/diagnostics/flash/engine
         flashpilot/diagnostics/flash/report
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
           'version "0.2.0"
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

;; Loads a plan (JSON + file-backed segments resolved) with the shared
;; recovery semantics; returns (values hardening plan*). Both the verify
;; surface and the flash surface consume it — what a host verifies is
;; what a host flashes.
(define (load-plan plan-path)
  (define text
    (with-handlers ([exn:verify-abort? raise]
                    [exn:fail? (lambda (e)
                                 (verify-abort "plan-unreadable" (exn-message e)))])
      (file->string plan-path)))
  (define hardening
    (with-handlers ([exn:verify-abort? raise]
                    [exn:flashpilot:validation?
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
               [exn:flashpilot:validation?
                (lambda (e)
                  (define message (exn-message e))
                  (if (string-prefix? message "Flash plan segment file not found")
                      (verify-abort "segment-unavailable" message)
                      (verify-abort "plan-invalid" message)))])
            (struct-copy uds-flash-segment seg
                         [data (bytes->list
                                (read-segment-file (uds-flash-segment-file seg)
                                                   base-dir))])))))
  (values hardening (struct-copy uds-flash-plan plan [segments loaded])))

(define (verify-plan-result plan-path)
  (define-values (hardening plan*) (load-plan plan-path))
  (define issues (plan-validation-issues plan*))
  (define blocking (plan-blocking-errors issues))
  (define fingerprint (flash-plan-fingerprint (uds-flash-plan-segments plan*)))
  (define expected (uds-flash-hardening-expected-fingerprint hardening))
  (define match (and expected (string-ci=? expected fingerprint)))
  (hasheq 'ok (and (null? blocking) (if expected match #t))
          'file plan-path
          'error 'null
          'findings (plan-issues->json issues)
          'segments (length (uds-flash-plan-segments plan*))
          'segmentDetails
          (for/list ([seg (in-list (uds-flash-plan-segments plan*))])
            (hasheq 'address (uds-flash-segment-address seg)
                    'bytes (length (uds-flash-segment-data seg))
                    'source (or (uds-flash-segment-file seg) "inline")))
          'session (or (uds-flash-plan-session plan*) 'null)
          'securityLevel (or (uds-flash-plan-security-level plan*) 'null)
          'dataLength (uds-flash-hardening-data-length hardening)
          'fingerprint fingerprint
          'expected (or expected 'null)
          'match (if expected match 'null)
          'onFail (or (let ([of (uds-flash-plan-on-fail plan*)])
                        (and of (symbol->string of)))
                      'null)
          'powerGuard (if (uds-flash-plan-power-guard plan*) 'configured 'null)
          'expectedIdentity (identity-json (uds-flash-plan-expected-identity plan*))))

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
;; Runs the plan against the simulated bench ECU — the native-host flash
;; execution surface. The engine's audited steps come back verbatim;
;; every failure is a bounded JSON, never a dead screen. Plan paths that
;; do not resolve on disk fall back to the bundled fixtures (packaged
;; apps ship examples/ inside the bundle).
(define (flash-plan-result plan-path)
  (define resolved
    (if (or (absolute-path? plan-path) (file-exists? plan-path))
        plan-path
        (let ([bundled (and (bundled-fixtures-dir)
                            (build-path (bundled-fixtures-dir)
                                        (last (explode-path (simplify-path plan-path)))))])
          (if (and bundled (file-exists? bundled))
              (path->string bundled)
              plan-path))))
  (define-values (hardening plan*) (load-plan resolved))
  ;; Stream the audited workflow to the hosts as it happens; the final
  ;; result still arrives through the RPC completion.
  (define result
    (sim-channel-flash sim-channel plan*
                       #:on-step
                       (lambda (step)
                         (emit-event! 'plan-progress
                                      (jsexpr->string (flash-step-summary->jsexpr step))))))
  ;; The hosts receive the full flashpilot.report/v1 shape — what the CLI
  ;; --report writes to disk is what the GUI surfaces, so a report is one
  ;; JSON dump away from traceability.
  (define report-ctx
    (make-flash-report-context resolved "sim-uds (embedded bench)"))
  (jsexpr->string
   (flash-report->jsexpr report-ctx hardening plan* result)))

(define (report-error-shape plan-path message [transport "sim-uds (embedded bench)"])
  (hasheq 'schema "flashpilot.report/v1"
          'startedAt (utc-now)
          'durationMs 0
          'ok #f
          'transport transport
          'plan plan-path
          'fingerprint 'null
          'expectedFingerprint 'null
          'expectedIdentity '()
          'bytes 0
          'segments 0
          'steps '()
          'error message))

(define-rpc (flash-plan [planPath String] : String)
  (with-handlers
      ([exn:verify-abort?
        (lambda (e)
          (jsexpr->string
           (report-error-shape planPath (exn:verify-abort-message e))))]
       [exn:fail:flash?
        (lambda (e)
          (define execution (exn:fail:flash-execution e))
          (jsexpr->string
           (hasheq 'schema "flashpilot.report/v1"
                   'startedAt 'null
                   'durationMs (uds-flash-result-duration-ms execution)
                   'ok (uds-flash-result-ok execution)
                   'transport "sim-uds (embedded bench)"
                   'plan planPath
                   'fingerprint 'null
                   'expectedFingerprint 'null
                   'expectedIdentity '()
                   'bytes (uds-flash-result-total-bytes execution)
                   'segments (uds-flash-result-segment-count execution)
                   'steps (map flash-step-summary->jsexpr
                               (uds-flash-result-steps execution))
                   'error (or (uds-flash-result-error execution) (exn-message e)))))]
       [exn:fail?
        (lambda (e)
          (jsexpr->string
           (report-error-shape planPath (exn-message e))))])
    (flash-plan-result planPath)))

;; Runs the plan over DoIP against a configured target — the real-target
;; path that mirrors the CLI (--transport doip --host H --reconnect N).
;; The connection object is one JSON string: {host, port, tester, ecu,
;; reconnectAttempts, reconnectDelayMs}. Same engine, same report shape,
;; same live plan-progress events as the embedded bench.
(define (parse-hex-word v label default)
  (cond
    [(not v) default]
    [(string? v)
     (define n (string->number (if (string-prefix? (string-downcase v) "0x")
                                   (substring v 2)
                                   v) 16))
     (or n default)]
    [else default]))

(define (flash-plan-remote-result plan-path connection)
  (define doc
    (with-handlers ([exn:fail? (lambda (e)
                                 (verify-abort "connection-invalid" (exn-message e)))])
      (let ([parsed (read-json (open-input-string connection))])
        (unless (hash? parsed)
          (raise (verify-abort "connection-invalid"
                               "connection must be a JSON object.")))
        parsed)))
  (define host (hash-ref doc 'host #f))
  (unless (and (string? host) (not (string-blank? host)))
    (raise (verify-abort "connection-invalid" "connection.host must be a non-empty string.")))
  (define port (or (hash-ref doc 'port #f) doip-port))
  (define tester (parse-hex-word (hash-ref doc 'tester #f) "tester" #x0E00))
  (define ecu (parse-hex-word (hash-ref doc 'ecu #f) "ecu" #x0E10))
  (define reconnect-attempts (or (hash-ref doc 'reconnectAttempts #f) 0))
  (define reconnect-delay (or (hash-ref doc 'reconnectDelayMs #f) 1000))
  (define transport-label (string-append "doip " host ":" (number->string port)))
  (define-values (hardening plan*)
    (with-handlers ([exn:verify-abort? raise])
      (load-plan plan-path)))
  (define channel
    (make-doip-uds-channel host port tester ecu
                           #:reconnect-attempts reconnect-attempts
                           #:reconnect-delay-ms reconnect-delay))
  (define result
    (doip-uds-channel-flash channel plan*
                            #:on-step
                            (lambda (step)
                              (emit-event! 'plan-progress
                                           (jsexpr->string
                                            (flash-step-summary->jsexpr step))))))
  (define report-ctx (make-flash-report-context plan-path transport-label))
  (jsexpr->string (flash-report->jsexpr report-ctx hardening plan* result)))

(define-rpc (flash-plan-remote [planPath String] [connection String] : String)
  (with-handlers
      ([exn:verify-abort?
        (lambda (e)
          (jsexpr->string
           (report-error-shape planPath (exn:verify-abort-message e)
                               "doip")))]
       [exn:fail:flash?
        (lambda (e)
          (define execution (exn:fail:flash-execution e))
          (jsexpr->string
           (hasheq 'schema "flashpilot.report/v1"
                   'startedAt 'null
                   'durationMs (uds-flash-result-duration-ms execution)
                   'ok (uds-flash-result-ok execution)
                   'transport "doip"
                   'plan planPath
                   'fingerprint 'null
                   'expectedFingerprint 'null
                   'expectedIdentity '()
                   'bytes (uds-flash-result-total-bytes execution)
                   'segments (uds-flash-result-segment-count execution)
                   'steps (map flash-step-summary->jsexpr
                               (uds-flash-result-steps execution))
                   'error (or (uds-flash-result-error execution) (exn-message e)))))]
       [exn:fail?
        (lambda (e)
          (jsexpr->string
           (report-error-shape planPath (exn-message e) "doip")))])
    (flash-plan-remote-result planPath connection)))

(define-rpc (dtc-read : String)
  (define result (sim-channel-request sim-channel (uds-read-dtcs #xFF) 1000 5000))
  (if (uds-request-result-positive result)
      (jsexpr->string (hasheq 'ok #t
                              'dtcs (parse-dtc-response
                                     (hex-parse (uds-request-result-response-hex result)))))
      (jsexpr->string (hasheq 'ok #f 'error "Negative response."))))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
