#lang racket/base

;; Crc32 + UdsFlashEngine.cs port: expectedIdentity gate -> session ->
;; security access -> erase -> per-segment download (RequestDownload/
;; TransferData/Exit with retries) -> CRC32 verify routine -> ECU reset,
;; every step audited.

(require racket/contract
         racket/format
         racket/list
         racket/string)

(require flashpilot/core/contracts
         flashpilot/diagnostics/flash/plans
         flashpilot/diagnostics/security-provider
         flashpilot/diagnostics/uds/protocol)

(provide (struct-out exn:fail:flash)
         crc32-compute
         make-flash-engine
         flash-execute
         make-key-derivers
         key-derivers-builtin)

;; ----------------------------------------------------------------------------
;; CRC32 (IEEE, reflected, 0xEDB88320)
;; ----------------------------------------------------------------------------

(define crc-table
  (for/vector ([i (in-range 256)])
    (let loop ([value i]
               [bit 0])
      (if (= bit 8)
          value
          (loop (if (odd? value)
                    (bitwise-xor (arithmetic-shift value -1) #xEDB88320)
                    (arithmetic-shift value -1))
                (add1 bit))))))

(define (crc32-compute segments)
  (define crc
    (for/fold ([crc #xFFFFFFFF]) ([seg (in-list segments)])
      (for/fold ([crc crc]) ([b (in-list (uds-flash-segment-data seg))])
        (bitwise-xor (arithmetic-shift crc -8)
                     (vector-ref crc-table (bitwise-and (bitwise-xor crc b) #xFF))))))
  (bitwise-xor crc #xFFFFFFFF))

;; ----------------------------------------------------------------------------
;; Key derivers (KeyDerivers.cs): named seed-to-key algorithms selectable
;; from driver settings; plan JSON never carries keys.
;; ----------------------------------------------------------------------------

;; equal?-based: deriver names arrive as strings from other modules/plans,
;; and eq? misses cross-module literals (CI-proven).
(define (key-derivers-builtin)
  (hash "xor0x5a"
          (lambda (seed) (map (lambda (b) (bitwise-xor b #x5A)) seed))
          "addindex"
          (lambda (seed)
            (for/list ([b (in-list seed)]
                       [i (in-naturals)])
              (bitwise-and (+ b i 1) #xFF)))))

(define (make-key-derivers [extra #f])
  (define base (key-derivers-builtin))
  (if (and extra (> (hash-count extra) 0))
      (for/hash ([(k v) (in-hash base)]) (values k v))
      base))

;; ----------------------------------------------------------------------------
;; Engine
;; ----------------------------------------------------------------------------

(struct flash-engine (client key-derivers))

(define (make-flash-engine client [key-derivers (make-key-derivers)])
  (flash-engine client key-derivers))

(define hex-up (lambda (n width) (string-upcase (~r n #:base 16 #:min-width width #:pad-string "0"))))

(define (engine-timing plan)
  (uds-timing (uds-flash-plan-p2-timeout-ms plan) (uds-flash-plan-p2-star-timeout-ms plan)))

(define (encode-routine-address-and-size address size)
  (define address-size (uds-address-length address))
  (append (for/list ([shift (in-range (* (sub1 address-size) 8) -1 -8)])
            (bitwise-and (arithmetic-shift address (- shift)) #xFF))
          (for/list ([shift (in-range 24 -1 -8)])
            (bitwise-and (arithmetic-shift size (- shift)) #xFF))))

;; Generic routine steps (routineSteps plan field): fire RoutineControl
;; start with the optional record, require a positive response, and audit
;; the raw bytes — vendor status semantics are never interpreted here.
(define (run-routine-steps! client
                            plan
                            add-step!
                            fail!
                            steps-at
                            position-name
                            #:cancel [cancel #f])
  (for ([step (in-list (filter (lambda (st) (eq? (routine-step-at st) steps-at))
                               (uds-flash-plan-routine-steps plan)))])
    (let ([sw (now-millis)])
      (define did-hex (hex-up (routine-step-routine-id step) 4))
      (define timing
        (if (routine-step-timeout-ms step)
            (uds-timing (routine-step-timeout-ms step)
                        (uds-flash-plan-p2-star-timeout-ms plan))
            (engine-timing plan)))
      (define payload
        (with-handlers
            ([exn:fail:uds?
              (lambda (e)
                (fail! (format "~a routine 0x~a failed: ~a"
                               position-name did-hex (exn-message e))
                       (and (exn:fail:uds-nrc e)
                            (format "0x~a" (hex-up (exn:fail:uds-nrc e) 2)))))])
          (uds-require-positive client
                                (uds-routine-control routine-start
                                                     (routine-step-routine-id step)
                                                     (routine-step-record step))
                                #:timing timing
                                #:cancel cancel)))
      (add-step!
       (flash-step-summary
        position-name
        #t
        (format "routine 0x~a accepted (~a)."
                did-hex (truncate-hex payload))
        (/ (- (now-millis) sw) 1.0)
        #f)))))

(define (flash-execute engine plan #:cancel [cancel #f])
  (define started (now-millis))
  (define steps '())
  (define total-bytes
    (for/sum ([seg (in-list (uds-flash-plan-segments plan))]) (length (uds-flash-segment-data seg))))
  (define client (flash-engine-client engine))

  (define (add-step! step)
    (set! steps (cons step steps)))
  (define (elapsed-ms)
    (/ (- (now-millis) started) 1.0))

  (define (fail! message [nrc #f])
    (add-step! (flash-step-summary "abort" #f message (elapsed-ms) nrc))
    (raise (exn:fail:flash (format "Flash workflow failed: ~a" message)
                           (current-continuation-marks)
                           (uds-flash-result #f
                                             (length (uds-flash-plan-segments plan))
                                             total-bytes
                                             (elapsed-ms)
                                             (reverse steps)
                                             message))))
  (define (fail-permanently! message [nrc #f])
    (add-step! (flash-step-summary "abort" #f message (elapsed-ms) nrc))
    (raise (exn:fail:flash:permanent
            (format "Flash workflow failed: ~a" message)
            (current-continuation-marks)
            (uds-flash-result #f
                              (length (uds-flash-plan-segments plan))
                              total-bytes
                              (elapsed-ms)
                              (reverse steps)
                              message))))

  ;; onFail recovery envelope: a non-permanent failure in the first
  ;; attempt replays the whole transaction once — fresh session, fresh
  ;; erase, semantically identical to the operator re-running the CLI.
  ;; Permanent failures (wrong ECU) and cancellation never replay.
  (define on-fail (uds-flash-plan-on-fail plan))
  (let recovery-loop ([attempt 1])
    (with-handlers
        ([exn:fail:flash:permanent? (lambda (e) (raise e))]
         [exn:fail:flash?
          (lambda (e)
            (cond
              [(and (= attempt 1) on-fail)
               ;; resetAndRetry: best-effort hard reset first — a stuck
               ;; programming session clears with the reset; outcome of
               ;; the reset itself never changes the decision.
               (when (eq? on-fail 'resetAndRetry)
                 (with-handlers ([exn:fail:uds? (lambda (_) (void))])
                   (uds-require-positive client (uds-ecu-reset 1)
                                         #:timing (uds-timing 5000 5000)
                                         #:cancel cancel)))
               (add-step! (flash-step-summary
                           "recovery" #t
                           (format "onFail ~a: replaying the transaction (attempt 2)." on-fail)
                           (elapsed-ms) #f))
               (recovery-loop 2)]
              [else (raise e)]))])
      (with-handlers
          ([exn:fail:uds?
            (lambda (e)
              (fail! (exn-message e)
                     (and (exn:fail:uds-nrc e)
                          (format "0x~a" (hex-up (exn:fail:uds-nrc e) 2)))))]
           [exn:benchpilot:cancelled?
            (lambda (e)
              (add-step! (flash-step-summary "abort" #f (exn-message e) (elapsed-ms) #f))
              (raise (exn:fail:flash:permanent
                      (format "Flash workflow failed: ~a" (exn-message e))
                      (current-continuation-marks)
                      (uds-flash-result #f
                                        (length (uds-flash-plan-segments plan))
                                        total-bytes
                                        (elapsed-ms)
                                        (reverse steps)
                                        (exn-message e)))))])
    ;; 0. ECU identification gate: read every configured DID and compare
    ;; exact bytes while the ECU still sits in whatever session it powered
    ;; up in — a wrong target aborts before session, unlock or erase ever
    ;; happen.
    (when (pair? (uds-flash-plan-expected-identity plan))
      (let ([sw (now-millis)])
        (for ([chk (in-list (uds-flash-plan-expected-identity plan))])
          (define did-hex (hex-up (identity-check-did chk) 4))
          (define payload
            (with-handlers
                ([exn:fail:uds?
                  (lambda (e)
                    (fail-permanently!
                     (format "ECU identity DID 0x~a read failed: ~a"
                             did-hex (exn-message e))
                     (and (exn:fail:uds-nrc e)
                          (format "0x~a" (hex-up (exn:fail:uds-nrc e) 2)))))])
              (uds-require-positive client
                                    (uds-read-did (identity-check-did chk))
                                    #:timing (engine-timing plan)
                                    #:cancel cancel)))
          ;; Positive response payload: echoed DID bytes then the value.
          (define actual (if (>= (length payload) 2) (drop payload 2) '()))
          (unless (equal? actual (identity-check-value chk))
            (fail-permanently!
             (format "ECU identity DID 0x~a mismatch: expected ~a, got ~a."
                     did-hex
                     (truncate-hex (identity-check-value chk))
                     (truncate-hex actual)))))
        (add-step! (flash-step-summary
                    "identity"
                    #t
                    (format "~a identity DID(s) matched."
                            (length (uds-flash-plan-expected-identity plan)))
                    (/ (- (now-millis) sw) 1.0)
                    #f))))

    ;; 1. Diagnostic session control.
    (let ([sw (now-millis)])
      (uds-require-positive client
                            (uds-diagnostic-session (uds-flash-plan-session plan))
                            #:timing (engine-timing plan)
                            #:cancel cancel)
      (add-step! (flash-step-summary "diagnostic-session"
                                     #t
                                     (format "session 0x~a accepted."
                                             (hex-up (uds-flash-plan-session plan) 2))
                                     (/ (- (now-millis) sw) 1.0)
                                     #f)))

    ;; 2. Security access (optional).
    (when (uds-flash-plan-security-level plan)
      (define deriver-name (uds-flash-plan-key-deriver plan))
      (define deriver
        (and deriver-name
             (or (hash-ref (flash-engine-key-derivers engine) deriver-name #f)
                 (resolve-key-deriver deriver-name))))
      (unless deriver
        (fail! (format "Plan references key deriver '~a' but no such deriver is registered."
                       deriver-name)))
      (define level (uds-flash-plan-security-level plan))
      (when (even? level)
        (fail! (format "Security access level 0x~a must be odd (request seed)." (hex-up level 2))))
      (let* ([sw (now-millis)]
             [seed-response (uds-require-positive client
                                                  (uds-security-request-seed level)
                                                  #:timing (engine-timing plan)
                                                  #:cancel cancel)]
             [seed (begin
                     (when (< (length seed-response) 2)
                       (fail! "SecurityAccess seed response malformed."))
                     (cdr seed-response))]
             [key (deriver seed)])
        (uds-require-positive client
                              (uds-security-send-key (add1 level) key)
                              #:timing (engine-timing plan)
                              #:cancel cancel)
        (add-step! (flash-step-summary
                    "security-access"
                    #t
                    (format "level 0x~a unlocked (seed ~a bytes)." (hex-up level 2) (length seed))
                    (/ (- (now-millis) sw) 1.0)
                    #f))))

    ;; 2b. Optional vendor pre-routines (condition checks before erase).
    (run-routine-steps! client plan add-step! fail!
                        'before-erase "pre-routine" #:cancel cancel)

    ;; 3. Erase per segment — single-shot by default; when the plan pins
    ;; erasePoll, repeat routine-start (same record — slice-erase ECUs
    ;; track the window internally) until the status byte reports done,
    ;; at most max-rounds rounds.
    (let ([sw (now-millis)]
          [poll (uds-flash-plan-erase-poll plan)])
      (define starts 0)
      (for ([seg (in-list (uds-flash-plan-segments plan))])
        (define record
          (encode-routine-address-and-size
           (uds-flash-segment-address seg)
           (length (uds-flash-segment-data seg))))
        (let erase-loop ([round 1])
          (set! starts (add1 starts))
          (define response
            (uds-require-positive client
                                  (uds-routine-control routine-start
                                                       (uds-flash-plan-erase-routine-id plan)
                                                       record)
                                  #:timing (if poll
                                               (uds-timing
                                                (erase-poll-round-timeout-ms poll)
                                                (uds-flash-plan-p2-star-timeout-ms plan))
                                               (engine-timing plan))
                                  #:cancel cancel))
          (define routine-id (bitwise-ior (arithmetic-shift (second response) 8) (third response)))
          (when (or (< (length response) 4)
                    (not (= (first response) routine-start))
                    (not (= routine-id (uds-flash-plan-erase-routine-id plan))))
            (fail! (format "Erase routine response mismatch (got ~a)." (bytes->hex response))))
          (when poll
            ;; Payload after the SID echoes [kind, id-hi, id-lo, status].
            (define status (if (>= (length response) 4) (fourth response) #f))
            (cond
              [(and status (= status (erase-poll-status-byte poll))) (void)]
              [(< round (erase-poll-max-rounds poll)) (erase-loop (add1 round))]
              [else
               (fail! (format "Erase did not reach status 0x~a within ~a start(s) (last status ~a)."
                              (hex-up (erase-poll-status-byte poll) 2)
                              (erase-poll-max-rounds poll)
                              (if status (format "0x~a" (hex-up status 2)) "absent")))]))))
      (add-step! (flash-step-summary "erase"
                                     #t
                                     (if poll
                                         (format "~a segment(s) erased via routine 0x~a in ~a start(s)."
                                                 (length (uds-flash-plan-segments plan))
                                                 (hex-up (uds-flash-plan-erase-routine-id plan) 4)
                                                 starts)
                                         (format "~a segment(s) erased via routine 0x~a."
                                                 (length (uds-flash-plan-segments plan))
                                                 (hex-up (uds-flash-plan-erase-routine-id plan) 4)))
                                     (/ (- (now-millis) sw) 1.0)
                                     #f)))

    ;; 4. Per-segment download.
    (for ([seg (in-list (uds-flash-plan-segments plan))])
      (let ([sw (now-millis)]
            [data (uds-flash-segment-data seg)]
            [retries 0])
        (define payload
          (uds-require-positive client
                                (uds-request-download (uds-flash-segment-address seg) (length data))
                                #:timing (engine-timing plan)
                                #:cancel cancel))
        (when (< (length payload) 2)
          (fail! "RequestDownload response malformed."))
        (define size-bytes (bitwise-and (first payload) #x0F))
        (define max-block-length
          (for/fold ([acc 0])
                    ([i (in-range 1 (add1 size-bytes))]
                     #:break (>= i (length payload)))
            (bitwise-ior (arithmetic-shift acc 8) (list-ref payload i))))
        (define max-block-payload
          (min (uds-flash-plan-max-block-payload plan) (max 2 (- max-block-length 2))))
        (let loop ([offset 0]
                   [block-sequence #x01])
          (when (< offset (length data))
            (define chunk-size (min (- (length data) offset) max-block-payload))
            (define retry-current
              (with-handlers ([exn:fail:uds? (lambda (e)
                                               (if (< retries (uds-flash-plan-block-retries plan))
                                                   (begin
                                                     (set! retries (add1 retries))
                                                     #t)
                                                   (raise e)))])
                (uds-require-positive client
                                      (uds-transfer-data block-sequence
                                                         (take (list-tail data offset) chunk-size))
                                      #:timing (engine-timing plan)
                                      #:cancel cancel)
                #f))
            (if retry-current
                (loop offset block-sequence)
                (let ([next (+ offset chunk-size)]
                      [next-seq (let ([s (add1 block-sequence)]) (if (zero? s) 1 s))])
                  (loop next next-seq)))))
        (uds-require-positive client
                              (uds-request-transfer-exit)
                              #:timing (engine-timing plan)
                              #:cancel cancel)
        (add-step! (flash-step-summary "download"
                                       #t
                                       (format "segment @0x~a: ~a bytes, ~aB blocks~a"
                                               (hex-up (uds-flash-segment-address seg) 8)
                                               (length data)
                                               max-block-payload
                                               (if (> retries 0)
                                                   (format ", ~a retried block(s)" retries)
                                                   ""))
                                       (/ (- (now-millis) sw) 1.0)
                                       #f))))

    ;; 5. Verify via CRC32 routine.
    (let ([sw (now-millis)])
      (define crc (crc32-compute (uds-flash-plan-segments plan)))
      (define response
        (uds-require-positive client
                              (uds-routine-control routine-start
                                                   (uds-flash-plan-verify-routine-id plan)
                                                   (list (bitwise-and (arithmetic-shift crc -24) #xFF)
                                                         (bitwise-and (arithmetic-shift crc -16) #xFF)
                                                         (bitwise-and (arithmetic-shift crc -8) #xFF)
                                                         (bitwise-and crc #xFF)))
                              #:timing (engine-timing plan)
                              #:cancel cancel))
      (define routine-id (bitwise-ior (arithmetic-shift (second response) 8) (third response)))
      (when (or (< (length response) 4)
                (not (= (first response) routine-start))
                (not (= routine-id (uds-flash-plan-verify-routine-id plan))))
        (fail! (format "Verify routine response mismatch (got ~a)." (bytes->hex response))))
      (add-step! (flash-step-summary "verify"
                                     #t
                                     (format "CRC32 0x~a over ~a bytes accepted by routine 0x~a."
                                             (hex-up crc 8)
                                             total-bytes
                                             (hex-up (uds-flash-plan-verify-routine-id plan) 4))
                                     (/ (- (now-millis) sw) 1.0)
                                     #f)))

    ;; 5b. Optional vendor post-routines (activations after verify).
    (run-routine-steps! client plan add-step! fail!
                        'after-verify "post-routine" #:cancel cancel)

    ;; 6. ECU reset.
    (let ([sw (now-millis)])
      (uds-require-positive client (uds-ecu-reset 1) #:timing (uds-timing 5000 5000) #:cancel cancel)
      (add-step!
       (flash-step-summary "ecu-reset" #t "hard reset accepted." (/ (- (now-millis) sw) 1.0) #f)))

    ;; 7. Post-reset confirmation gate (optional): poll one DID until its
    ;; exact bytes match — the ECU must prove it came back healthy on the
    ;; new image before this run reports success.
    (define gate (uds-flash-plan-post-reset-gate plan))
    (when gate
      (let ([sw (now-millis)]
            [deadline (+ (now-millis) (post-reset-gate-timeout-ms gate))]
            [last-payload #f])
        (let poll ()
          (sleep (/ (post-reset-gate-interval-ms gate) 1000.0))
          (define read-result
            (with-handlers
                ([exn:fail:uds?
                  (lambda (e)
                    (fail! (format "Post-reset gate DID 0x~a read failed: ~a"
                                   (hex-up (post-reset-gate-did gate) 4)
                                   (exn-message e))
                           (and (exn:fail:uds-nrc e)
                                (format "0x~a" (hex-up (exn:fail:uds-nrc e) 2)))))])
              (uds-require-positive client
                                    (uds-read-did (post-reset-gate-did gate))
                                    #:timing (engine-timing plan)
                                    #:cancel cancel)))
          (set! last-payload
                (if (>= (length read-result) 2) (drop read-result 2) '()))
          (cond
            [(equal? last-payload (post-reset-gate-value gate))
             (add-step!
              (flash-step-summary
               "post-reset-gate"
               #t
               (format "DID 0x~a matched after ~a ms."
                       (hex-up (post-reset-gate-did gate) 4)
                       (inexact->exact (floor (- (now-millis) sw))))
               (/ (- (now-millis) sw) 1.0)
               #f))]
            [(> (now-millis) deadline)
             (fail! (format "Post-reset gate DID 0x~a never matched within ~a ms (last value ~a)."
                            (hex-up (post-reset-gate-did gate) 4)
                            (post-reset-gate-timeout-ms gate)
                            (truncate-hex last-payload)))]
            [else (poll)]))))

        (uds-flash-result #t
                          (length (uds-flash-plan-segments plan))
                          total-bytes
                          (elapsed-ms)
                          (reverse steps)
                          #f)))))

(struct exn:fail:flash exn:fail (execution) #:transparent)

;; Permanent failures (wrong ECU, unsupported identity DID) never enter a
;; recovery round — a wrong target must not be touched twice.
(struct exn:fail:flash:permanent exn:fail:flash ())
