#lang racket/base

;; Flash reports: the durable evidence artifact behind one flash attempt.
;; vFlash-class flashing ends with a report file, not just a console line —
;; agents, benches and production traceability read the same schema. The
;; CLI's stdout JSON stays byte-identical; the report is additive and
;; written for failed attempts too (the failure is the evidence that
;; matters most).

(require json
         racket/file)

(require flashpilot/core/contracts
         flashpilot/diagnostics/flash/plans)

(provide report-schema
         (struct-out flash-report-context)
         make-flash-report-context
         flash-report->jsexpr
         write-flash-report)

(define report-schema "flashpilot.report/v1")

(struct flash-report-context (plan-path transport-label started-utc) #:transparent)

;; Capture the run context before the engine touches the ECU: plan path,
;; transport label and the UTC start time land in every report, success or
;; failure.
(define (make-flash-report-context plan-path transport-label)
  (flash-report-context plan-path transport-label (utc-now)))

;; The report records what ran, in order: the engine's audited steps, the
;; identity expectations and image fingerprint that gated the run, and the
;; outcome. Bounded text throughout — a report never leaks more than the
;; stdout evidence does.
(define (flash-report->jsexpr ctx hardening plan result)
  (hasheq 'schema report-schema
          'startedAt (flash-report-context-started-utc ctx)
          'durationMs (uds-flash-result-duration-ms result)
          'ok (uds-flash-result-ok result)
          'transport (flash-report-context-transport-label ctx)
          'plan (flash-report-context-plan-path ctx)
          'fingerprint (flash-plan-fingerprint (uds-flash-plan-segments plan))
          'expectedFingerprint
          (or (uds-flash-hardening-expected-fingerprint hardening) 'null)
          'expectedIdentity (identity-json (uds-flash-plan-expected-identity plan))
          'bytes (uds-flash-result-total-bytes result)
          'segments (uds-flash-result-segment-count result)
          'steps (map flash-step-summary->jsexpr (uds-flash-result-steps result))
          'error (or (uds-flash-result-error result) 'null)))

(define (write-flash-report path jsexpr)
  (with-output-to-file path #:exists 'replace
    (lambda () (write-json jsexpr) (newline))))
