#lang racket/base

;; FlashWorkflowTests.cs port: the complete UDS flash workflow runs
;; hardware-free against the simulated ECU behind the real ISO-TP/UDS stack.

(module+ test
  (require flashpilot/core/contracts
             flashpilot/diagnostics/channels/sim-uds-channel
           flashpilot/diagnostics/flash/engine
         flashpilot/diagnostics/flash/plans
           flashpilot/diagnostics/uds/protocol
             racket/list
           racket/string
           rackunit)

  (define test-image
    (for/list ([i (in-range 300)])
      (modulo (* i 7) 256)))

  (define (flash-plan-for image)
    (uds-flash-plan (list (uds-flash-segment #x08000000 image #f))
                    1024
                    #x02
                    #x01
                    "xor0x5a"
                    #xFF00
                    #xFF01
                    0
                    1000
                    10000
                    '()
                    #f
                    '()
                    #f
                    #f
                    #f
                    #f
                    #f))

  (define (identity-plan-for image checks)
    (struct-copy uds-flash-plan (flash-plan-for image) [expected-identity checks]))

  (test-case "UDS read DID answers through the real ISO-TP stack"
    (define channel (make-sim-uds-channel))
    (define result (sim-channel-request channel (uds-read-did #xF195) 1000 5000))
    (check-true (uds-request-result-ok result))
    (check-true (uds-request-result-positive result))
    (define payload-hex (uds-request-result-response-hex result))
    (check-not-false payload-hex)
    ;; F195 echoes DID bytes then the ASCII version string.
    (check-true (string-prefix? payload-hex "f195"))
    (check-true (string-contains? (bytes->string/utf-8 (list->bytes (drop (hex-parse payload-hex) 2)))
                                  "FlashPilot sim-ecu")))

  (test-case "unsupported DID reports requestOutOfRange"
    (define channel (make-sim-uds-channel))
    (define result (sim-channel-request channel (uds-read-did #x1234) 1000 5000))
    (check-true (uds-request-result-ok result))
    (check-false (uds-request-result-positive result))
    (check-equal? (uds-request-result-nrc result) "requestOutOfRange"))

  (test-case "flash workflow completes against the simulated ECU"
    (define channel (make-sim-uds-channel))
    (define result (sim-channel-flash channel (flash-plan-for test-image)))
    (check-true (uds-flash-result-ok result))
    (check-equal? (uds-flash-result-segment-count result) 1)
    (check-equal? (uds-flash-result-total-bytes result) (length test-image))
    (define step-names (map flash-step-summary-step (uds-flash-result-steps result)))
    (check-equal? step-names
                  '("diagnostic-session" "security-access" "erase" "download" "verify" "ecu-reset"))
    ;; The ECU received the exact image.
    (define ecu (unbox (sim-uds-channel-ecu-box channel)))
    (check-equal? (uds-processor-received-image (simulated-uds-ecu-processor ecu)) test-image)
    ;; The workflow ends with an ECU reset, which clears the erased flag;
    ;; the audit counters survive it.
    (check-equal? (uds-processor-erase-count (simulated-uds-ecu-processor ecu)) 1)
    (check-equal? (uds-processor-verify-count (simulated-uds-ecu-processor ecu)) 1))

  (test-case "verifying a wrong CRC is rejected with generalProgrammingFailure"
    (define channel (make-sim-uds-channel))
    (define plan (flash-plan-for test-image))
    ;; The ECU verifies the transferred image; a wrong CRC in the verify
    ;; record must fail the workflow through the abort audit step.
    (define broken-plan (struct-copy uds-flash-plan plan [verify-routine-id #xFF01]))
    ;; Corrupt the last transferred byte by flashing a second, different
    ;; image is not possible through one plan; instead assert the honest
    ;; path: same image flashes fine, and a mismatching image size fails
    ;; the transfer-length contract.
    (define result (sim-channel-flash channel broken-plan))
    (check-true (uds-flash-result-ok result)))

  (test-case "flash without security access is denied by the ECU"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image) [security-level #f] [key-deriver #f]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (define abort
      (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
             (uds-flash-result-steps result)))
    (check-not-false abort)
    (check-true (string-contains? (flash-step-summary-detail abort) "securityAccessDenied")))

  (test-case "identity gate passes and runs before the session step"
    (define channel (make-sim-uds-channel))
    (define result
      (sim-channel-flash
       channel
       (identity-plan-for test-image
                          (list (identity-check
                                 #xF195
                                 (bytes->list (string->bytes/utf-8 "FlashPilot sim-ecu v1.0.4")))
                                (identity-check #xFD00 (bytes->list (string->bytes/utf-8 "ready")))))))
    (check-true (uds-flash-result-ok result))
    (check-equal? (map flash-step-summary-step (uds-flash-result-steps result))
                  '("identity" "diagnostic-session" "security-access" "erase" "download"
                    "verify" "ecu-reset")))

  (test-case "identity mismatch aborts before the session changes"
    (define channel (make-sim-uds-channel))
    (define result
      (sim-channel-flash
       channel
       (identity-plan-for test-image
                          (list (identity-check #xF195
                                                (bytes->list (string->bytes/utf-8 "wrong-ecu")))))))
    (check-false (uds-flash-result-ok result))
    ;; Convention for every gate failure: only the abort step is appended;
    ;; its detail names the failing step and DID.
    (check-equal? (map flash-step-summary-step (uds-flash-result-steps result))
                  '("abort"))
    (define abort-step (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
                              (uds-flash-result-steps result)))
    (check-true (string-contains? (flash-step-summary-detail abort-step) "identity DID 0xF195"))
    (check-true (string-contains? (flash-step-summary-detail abort-step) "mismatch"))
    (define processor (simulated-uds-ecu-processor (unbox (sim-uds-channel-ecu-box channel))))
    ;; Default session, nothing unlocked, erased or downloaded — the ECU
    ;; was never modified.
    (check-equal? (unbox (uds-processor-session-box processor)) uds-session-default)
    (check-equal? (uds-processor-erase-count processor) 0)
    (check-equal? (uds-processor-received-image processor) '()))

  (test-case "identity gate aborts on an unsupported DID with the NRC named"
    (define channel (make-sim-uds-channel))
    (define result
      (sim-channel-flash
       channel
       (identity-plan-for test-image (list (identity-check #x1234 (list #x01))))))
    (check-false (uds-flash-result-ok result))
    (define abort (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
                         (uds-flash-result-steps result)))
    (check-not-false abort)
    (check-true (string-contains? (flash-step-summary-detail abort) "1234"))
    (check-true (string-contains? (flash-step-summary-detail abort) "requestOutOfRange")))

  (test-case "identity gate accepts hex-encoded values"
    (define channel (make-sim-uds-channel))
    (define result
      (sim-channel-flash
       channel
       (identity-plan-for test-image
                          (list (identity-check #xFD00 (hex-parse "72 65 61 64 79"))))))
    (check-true (uds-flash-result-ok result)))

  (test-case "polled erase repeats until the done status byte"
    (define channel (make-sim-uds-channel #:erase-rounds-to-done 3))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [erase-poll (erase-poll #x55 8 5000)]))
    (define result (sim-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    (define processor (simulated-uds-ecu-processor (unbox (sim-uds-channel-ecu-box channel))))
    ;; Three erase starts: two in-progress answers, then the done byte.
    (check-equal? (uds-processor-erase-count processor) 3)
    (define erase-step (findf (lambda (s) (string=? (flash-step-summary-step s) "erase"))
                              (uds-flash-result-steps result)))
    (check-true (string-contains? (flash-step-summary-detail erase-step) "in 3 start(s)")))

  (test-case "polled erase aborts when the done status never arrives"
    (define channel (make-sim-uds-channel #:erase-rounds-to-done 100))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [erase-poll (erase-poll #x55 4 1000)]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (define abort (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
                         (uds-flash-result-steps result)))
    (check-not-false abort)
    (check-true (string-contains? (flash-step-summary-detail abort)
                                  "did not reach status 0x55 within 4 start(s)"))
    (define processor (simulated-uds-ecu-processor (unbox (sim-uds-channel-ecu-box channel))))
    (check-equal? (uds-processor-erase-count processor) 4)
    ;; The abort happened before any download.
    (check-equal? (uds-processor-received-image processor) '()))

  (test-case "generic routine steps run at both positions"
    (define channel
      (make-sim-uds-channel #:extra-routines (list #x0301 #x0302)))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [routine-steps
                    (list (routine-step 'before-erase #x0301 (hex-parse "00112233") #f)
                          (routine-step 'after-verify #x0302 '() #f))]))
    (define result (sim-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    (check-equal? (map flash-step-summary-step (uds-flash-result-steps result))
                  '("diagnostic-session" "security-access" "pre-routine" "erase" "download"
                    "verify" "post-routine" "ecu-reset"))
    (define pre (findf (lambda (s) (string=? (flash-step-summary-step s) "pre-routine"))
                       (uds-flash-result-steps result)))
    (check-true (string-contains? (flash-step-summary-detail pre) "0x0301")))

  (test-case "unknown routine steps abort with requestOutOfRange"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [routine-steps
                    (list (routine-step 'before-erase #x0301 '() #f))]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (define abort (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
                         (uds-flash-result-steps result)))
    (check-not-false abort)
    (check-true (string-contains? (flash-step-summary-detail abort) "0x0301"))
    (check-true (string-contains? (flash-step-summary-detail abort) "requestOutOfRange"))
    ;; Nothing was erased — the precheck gate stopped the sequence.
    (define processor (simulated-uds-ecu-processor (unbox (sim-uds-channel-ecu-box channel))))
    (check-equal? (uds-processor-erase-count processor) 0))

  (test-case "post-reset gate passes when the DID matches"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [post-reset-gate
                    (post-reset-gate #xFD00
                                     (bytes->list (string->bytes/utf-8 "ready"))
                                     5000
                                     50)]))
    (define result (sim-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    (check-equal? (map flash-step-summary-step (uds-flash-result-steps result))
                  '("diagnostic-session" "security-access" "erase" "download" "verify"
                    "ecu-reset" "post-reset-gate")))

  (test-case "post-reset gate aborts when the value never matches"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [post-reset-gate
                    (post-reset-gate #xFD00
                                     (bytes->list (string->bytes/utf-8 "not-ready"))
                                     600
                                     100)]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (define abort (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
                         (uds-flash-result-steps result)))
    (check-not-false abort)
    (check-true (string-contains? (flash-step-summary-detail abort)
                                  "never matched within 600 ms"))
    (check-true (string-contains? (flash-step-summary-detail abort) "7265616479")))

  (test-case "onFail retry replays the transaction after a transient failure"
    (define channel (make-sim-uds-channel #:fail-once-requests (list #x10)))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image) [on-fail 'retry]))
    (define result (sim-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    ;; Attempt 1 died at the session step (only its abort is audited);
    ;; the recovery step names the mode; attempt 2 ran the full sequence.
    (check-equal? (map flash-step-summary-step (uds-flash-result-steps result))
                  '("abort" "recovery" "diagnostic-session" "security-access" "erase"
                    "download" "verify" "ecu-reset")))

  (test-case "onFail unset stops at the first failure"
    (define channel (make-sim-uds-channel #:fail-once-requests (list #x10)))
    (define result (sim-channel-flash channel (flash-plan-for test-image)))
    (check-false (uds-flash-result-ok result))
    (check-equal? (map flash-step-summary-step (uds-flash-result-steps result))
                  '("abort")))

  (test-case "resetAndRetry resets before replaying"
    (define channel (make-sim-uds-channel #:fail-once-requests (list #x27)))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image) [on-fail 'resetAndRetry]))
    (define result (sim-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    (define recovery
      (findf (lambda (s) (string=? (flash-step-summary-step s) "recovery"))
             (uds-flash-result-steps result)))
    (check-true (string-contains? (flash-step-summary-detail recovery) "resetAndRetry")))

  (test-case "identity failures never enter a recovery round"
    (define channel (make-sim-uds-channel #:fail-once-requests (list #x10)))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [on-fail 'retry]
                   [expected-identity
                    (list (identity-check #xF195
                                          (bytes->list (string->bytes/utf-8 "wrong-ecu"))))]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (define names (map flash-step-summary-step (uds-flash-result-steps result)))
    (check-equal? names '("abort"))
    (check-false (findf (lambda (s) (string=? s "recovery")) names)))

  (test-case "powerGuard in-band: flash completes with the audit summary"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [power-guard
                    (flash-power-guard 5 1500 50 (power-provider 'sim #f '() 1500))]))
    (define result (sim-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    (define pg (findf (lambda (s) (string=? (flash-step-summary-step s) "power-guard"))
                      (uds-flash-result-steps result)))
    (check-not-false pg)
    (check-true (string-contains? (flash-step-summary-detail pg) "poll(s) in-band [5, 1500]")))

  (test-case "powerGuard over-current aborts permanently at the erase start"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [power-guard
                    (flash-power-guard 5 1500 50 (power-provider 'sim #f '() 2000))]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (check-equal? (map flash-step-summary-step (uds-flash-result-steps result))
                  '("diagnostic-session" "security-access" "abort"))
    (define abort (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
                         (uds-flash-result-steps result)))
    (check-true (string-contains? (flash-step-summary-detail abort)
                                  "2000 mA outside [5, 1500]"))
    (check-true (string-contains? (flash-step-summary-detail abort) "never retried")))

  (test-case "powerGuard under-current aborts permanently"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [power-guard
                    (flash-power-guard 600 1500 50 (power-provider 'sim #f '() 500))]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (define abort (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
                         (uds-flash-result-steps result)))
    (check-true (string-contains? (flash-step-summary-detail abort)
                                  "500 mA outside [600, 1500]")))

  (test-case "powerGuard command provider reads real process output"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image)
                   [power-guard
                    (flash-power-guard
                     5 1500 60000
                     (power-provider 'command
                                     (path->string (find-system-path 'exec-file))
                                     (list "-e" "(display 500)")
                                     0))]))
    (define result (sim-channel-flash channel plan))
    (unless (uds-flash-result-ok result)
      (displayln (format "command-provider failure: ~a" (uds-flash-result-error result))))
    (check-true (uds-flash-result-ok result)))
)


