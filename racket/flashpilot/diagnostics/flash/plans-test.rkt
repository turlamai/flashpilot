#lang racket/base

;; Plan parsing tests for the expectedIdentity gate: entry forms and their
;; honest validation errors. Parse-level only — the gate's runtime
;; behavior against the simulated ECU is covered by workflow-test.

(module+ test
  (require flashpilot/core/contracts
           flashpilot/diagnostics/flash/plans
           racket/list
           rackunit)

  (define (parse plan-json)
    (uds-flash-hardening-plan (read-flash-plan-json plan-json)))

  (test-case "expectedIdentity absent yields no gate"
    (check-equal? (uds-flash-plan-expected-identity (parse "{}")) '()))

  (test-case "identity entries parse as did + exact value bytes"
    (define plan
      (parse
       "{\"expectedIdentity\":[{\"did\":\"0xF195\",\"value\":\"abc\"},{\"did\":65280,\"valueHex\":\"00 ff\"}]}"))
    (define checks (uds-flash-plan-expected-identity plan))
    (check-equal? (length checks) 2)
    (check-equal? (identity-check-did (first checks)) #xF195)
    (check-equal? (identity-check-value (first checks))
                  (bytes->list (string->bytes/utf-8 "abc")))
    (check-equal? (identity-check-did (second checks)) #xFF00)
    (check-equal? (identity-check-value (second checks)) '(0 #xff)))

  (test-case "both value and valueHex is a validation error"
    (check-exn exn:benchpilot:validation?
               (lambda ()
                 (parse
                  "{\"expectedIdentity\":[{\"did\":1,\"value\":\"a\",\"valueHex\":\"00\"}]}"))))

  (test-case "neither value nor valueHex is a validation error"
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"expectedIdentity\":[{\"did\":1}]}"))))

  (test-case "bad or out-of-range DID is a validation error"
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"expectedIdentity\":[{\"did\":\"zz\",\"value\":\"a\"}]}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"expectedIdentity\":[{\"did\":65536,\"value\":\"a\"}]}"))))

  (test-case "empty value is a validation error"
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"expectedIdentity\":[{\"did\":1,\"value\":\"\"}]}"))))

  (test-case "non-list expectedIdentity is a validation error"
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"expectedIdentity\":{\"did\":1}}"))))

  (test-case "identity-json serializes to did + valueHex"
    (check-equal?
     (identity-json (list (identity-check #xFD00 (bytes->list (string->bytes/utf-8 "ready")))))
     (list (hasheq 'did #xFD00 'valueHex "7265616479"))))
)
