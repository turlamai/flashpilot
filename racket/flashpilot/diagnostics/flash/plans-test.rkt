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

  (test-case "erasePoll absent yields no polling"
    (check-false (uds-flash-plan-erase-poll (parse "{}"))))

  (test-case "erasePoll parses all three required fields"
    (define poll
      (uds-flash-plan-erase-poll
       (parse "{\"erasePoll\":{\"statusByte\":\"0x55\",\"maxRounds\":8,\"roundTimeoutMs\":5000}}")))
    (check-equal? (erase-poll-status-byte poll) #x55)
    (check-equal? (erase-poll-max-rounds poll) 8)
    (check-equal? (erase-poll-round-timeout-ms poll) 5000))

  (test-case "erasePoll statusByte accepts plain integers"
    (check-equal? (erase-poll-status-byte
                   (uds-flash-plan-erase-poll
                    (parse "{\"erasePoll\":{\"statusByte\":85,\"maxRounds\":1,\"roundTimeoutMs\":10}}")))
                  85))

  (test-case "routineSteps parse at/id/record/timeout"
    (define steps
      (uds-flash-plan-routine-steps
       (parse "{\"routineSteps\":[{\"at\":\"before-erase\",\"routineId\":\"0x0301\",\"record\":\"00112233\",\"timeoutMs\":25000},{\"at\":\"after-verify\",\"routineId\":771}]}")))
    (check-equal? (length steps) 2)
    (check-equal? (routine-step-at (first steps)) 'before-erase)
    (check-equal? (routine-step-routine-id (first steps)) #x0301)
    (check-equal? (routine-step-record (first steps)) '(0 #x11 #x22 #x33))
    (check-equal? (routine-step-timeout-ms (first steps)) 25000)
    (check-equal? (routine-step-at (second steps)) 'after-verify)
    (check-equal? (routine-step-record (second steps)) '())
    (check-false (routine-step-timeout-ms (second steps))))

  (test-case "routineSteps reject bad position, id and timeout"
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"routineSteps\":[{\"at\":\"mid-verify\",\"routineId\":1}]}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"routineSteps\":[{\"at\":\"before-erase\",\"routineId\":65536}]}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"routineSteps\":[{\"at\":\"before-erase\",\"routineId\":1,\"timeoutMs\":0}]}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"routineSteps\":[{\"at\":\"before-erase\",\"routineId\":1,\"record\":\"abc\"}]}"))))

  (test-case "postResetGate parses did/value/timeout/interval"
    (define gate
      (uds-flash-plan-post-reset-gate
       (parse "{\"postResetGate\":{\"did\":\"0xFD00\",\"value\":\"ready\",\"timeoutMs\":30000,\"intervalMs\":250}}")))
    (check-equal? (post-reset-gate-did gate) #xFD00)
    (check-equal? (post-reset-gate-value gate) (bytes->list (string->bytes/utf-8 "ready")))
    (check-equal? (post-reset-gate-timeout-ms gate) 30000)
    (check-equal? (post-reset-gate-interval-ms gate) 250))

  (test-case "postResetGate defaults interval and rejects bad fields"
    (define gate
      (uds-flash-plan-post-reset-gate
       (parse "{\"postResetGate\":{\"did\":65280,\"valueHex\":\"7265616479\",\"timeoutMs\":1000}}")))
    (check-equal? (post-reset-gate-interval-ms gate) 500)
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"postResetGate\":{\"did\":1,\"value\":\"a\",\"valueHex\":\"00\",\"timeoutMs\":100}}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"postResetGate\":{\"did\":1,\"value\":\"a\"}}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"postResetGate\":{\"did\":1,\"value\":\"a\",\"timeoutMs\":0}}"))))

  (test-case "powerGuard parses bounds and the required provider"
    (define guard
      (uds-flash-plan-power-guard
       (parse "{\"powerGuard\":{\"minMa\":5,\"maxMa\":1500,\"pollMs\":100,\"provider\":{\"kind\":\"sim\",\"ma\":1200}}}")))
    (check-equal? (flash-power-guard-min-ma guard) 5)
    (check-equal? (flash-power-guard-max-ma guard) 1500)
    (check-equal? (flash-power-guard-poll-ms guard) 100)
    (define prov (flash-power-guard-provider guard))
    (check-equal? (power-provider-kind prov) 'sim)
    (check-equal? (power-provider-ma prov) 1200))

  (test-case "powerGuard defaults poll and sim ma, parses command form"
    (define guard
      (uds-flash-plan-power-guard
       (parse "{\"powerGuard\":{\"minMa\":0,\"maxMa\":2000,\"provider\":{\"kind\":\"command\",\"command\":\"./bench-power\",\"args\":[\"--port\",\"com1\"],\"ma\":9}}}")))
    (check-equal? (flash-power-guard-poll-ms guard) 200)
    (define prov (flash-power-guard-provider guard))
    (check-equal? (power-provider-kind prov) 'command)
    (check-equal? (power-provider-command prov) "./bench-power")
    (check-equal? (power-provider-args prov) (list "--port" "com1"))
    ;; ma is meaningless for command providers; parsing still records it.
    (check-equal? (power-provider-ma prov) 9))

  (test-case "powerGuard without a provider is a validation error"
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"powerGuard\":{\"minMa\":5,\"maxMa\":1500}}"))))

  (test-case "powerGuard rejects unknown provider kind and non-integer bounds"
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"powerGuard\":{\"minMa\":5,\"maxMa\":1500,\"provider\":{\"kind\":\"magic\"}}}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"powerGuard\":{\"minMa\":\"x\",\"maxMa\":1500,\"provider\":{\"kind\":\"sim\"}}}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"powerGuard\":{\"minMa\":5,\"maxMa\":1500,\"provider\":{\"kind\":\"command\"}}}"))))

  (test-case "erasePoll rejects out-of-range or missing fields"
    (define (parse-erase json) (parse json))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"erasePoll\":{\"statusByte\":256,\"maxRounds\":1,\"roundTimeoutMs\":10}}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"erasePoll\":{\"statusByte\":\"0x55\",\"roundTimeoutMs\":10}}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"erasePoll\":{\"statusByte\":\"0x55\",\"maxRounds\":0,\"roundTimeoutMs\":10}}")))
    (check-exn exn:benchpilot:validation?
               (lambda () (parse "{\"erasePoll\":{\"statusByte\":\"0x55\",\"maxRounds\":2}}"))))
)
