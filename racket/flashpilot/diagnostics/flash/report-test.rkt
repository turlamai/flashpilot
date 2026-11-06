#lang racket/base

;; Flash report tests: the evidence artifact for a successful run, a
;; failed run and the file round-trip — all hardware-free against the
;; simulated ECU.

(module+ test
  (require json
           racket/file
           racket/list
           racket/string
           rackunit)

  (require flashpilot/core/contracts
           flashpilot/diagnostics/channels/sim-uds-channel
           flashpilot/diagnostics/flash/plans
           flashpilot/diagnostics/flash/report)

  (define (plan-with-identity identity-json-text)
    (read-flash-plan-json
     (format "{\"segments\":[{\"address\":\"0x08000000\",\"data\":\"DEADBEEF\"}],\"session\":2,\"securityLevel\":1,\"keyDeriver\":\"xor0x5a\",~a}"
             identity-json-text)))

  (test-case "report captures a successful sim flash end to end"
    (define hardening (plan-with-identity "\"expectedIdentity\":[{\"did\":\"0xFD00\",\"value\":\"ready\"}]"))
    (define plan (uds-flash-hardening-plan hardening))
    (define channel (make-sim-uds-channel))
    (define ctx (make-flash-report-context "plan.json" "iso-tp/can (simulated)"))
    (define result (sim-channel-flash channel plan))
    (define report (flash-report->jsexpr ctx hardening plan result))
    (check-equal? (hash-ref report 'schema) "flashpilot.report/v1")
    (check-true (hash-ref report 'ok))
    (check-equal? (hash-ref report 'transport) "iso-tp/can (simulated)")
    (check-equal? (hash-ref report 'plan) "plan.json")
    (check-equal? (hash-ref report 'bytes) 4)
    (check-equal? (hash-ref report 'fingerprint)
                  (flash-plan-fingerprint (uds-flash-plan-segments plan)))
    (check-equal? (hash-ref report 'expectedFingerprint) 'null)
    (check-equal? (hash-ref report 'expectedIdentity)
                  (list (hasheq 'did #xFD00 'valueHex "7265616479")))
    ;; The identity gate runs first, so the audited steps are seven.
    (check-equal? (length (hash-ref report 'steps)) 7)
    (check-equal? (hash-ref (first (hash-ref report 'steps)) 'step) "identity")
    (check-true (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T"
                               (hash-ref report 'startedAt))))

  (test-case "failed runs report the abort evidence"
    (define hardening
      (plan-with-identity "\"expectedIdentity\":[{\"did\":\"0xF195\",\"value\":\"wrong-ecu\"}]"))
    (define plan (uds-flash-hardening-plan hardening))
    (define channel (make-sim-uds-channel))
    (define ctx (make-flash-report-context "plan.json" "iso-tp/can (simulated)"))
    (define result (sim-channel-flash channel plan))
    (define report (flash-report->jsexpr ctx hardening plan result))
    (check-false (hash-ref report 'ok))
    (check-true (string-contains? (hash-ref report 'error) "identity DID 0xF195 mismatch"))
    (check-equal? (hash-ref (last (hash-ref report 'steps)) 'step) "abort"))

  (test-case "write-flash-report round-trips through disk"
    (define hardening (plan-with-identity "\"expectedIdentity\":[{\"did\":\"0xFD00\",\"value\":\"ready\"}]"))
    (define plan (uds-flash-hardening-plan hardening))
    (define channel (make-sim-uds-channel))
    (define ctx (make-flash-report-context "plan.json" "sim"))
    (define result (sim-channel-flash channel plan))
    (define path (make-temporary-file "flashpilot-report-~a.json"))
    (write-flash-report path (flash-report->jsexpr ctx hardening plan result))
    (define back (read-json (open-input-string (file->string path))))
    (check-equal? (hash-ref back 'schema) "flashpilot.report/v1")
    (check-true (hash-ref back 'ok))
    (when (file-exists? path) (delete-file path)))
)
