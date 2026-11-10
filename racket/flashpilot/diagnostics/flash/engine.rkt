#lang racket/base

;; Crc32 + UdsFlashEngine.cs port: expectedIdentity gate -> session ->
;; security access -> erase -> per-segment download (RequestDownload/
;; TransferData/Exit with retries) -> CRC32 verify routine -> ECU reset,
;; every step audited.

(require racket/contract
         racket/format
         racket/list
         racket/port
         racket/system
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
         key-derivers-builtin
         adopt-max-block-length)

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

;; constant:<hex> — a fixed key regardless of seed. Development benches
;; commonly pin a constant key; the hex travels in the plan (reviewable,
;; never hidden), so weak policies stay visible rather than obscure.
(define (constant-deriver-from-name name)
  (and (string-prefix? name "constant:")
       (let* ([hex (substring name 9)]
              [bytes (hex-parse hex)])
         (lambda (_seed) bytes))))

(define (make-key-derivers [extra #f])
  (define base (key-derivers-builtin))
  (if (and extra (> (hash-count extra) 0))
      (for/hash ([(k v) (in-hash base)]) (values k v))
      base))

;; ----------------------------------------------------------------------------
;; Engine
;; ----------------------------------------------------------------------------

(struct flash-engine (client key-derivers revive-link revive-context))

;; revive-link: optional (exn? -> boolean). Called with a non-UDS failure
;; during the post-reset gate poll; returning #t means the transport
;; re-established the link (e.g. a DoIP reconnect) and the poll may
;; continue. revive-context: optional (-> client) resolving the fresh
;; client after a revive.
(define (make-flash-engine client
                           [key-derivers (make-key-derivers)]
                           #:revive-link [revive-link #f]
                           #:revive-context [revive-context #f])
  (flash-engine client key-derivers revive-link revive-context))

(define (engine-gate-client engine)
  (define revive-context (flash-engine-revive-context engine))
  (if revive-context (revive-context) (flash-engine-client engine)))

(define hex-up (lambda (n width) (string-upcase (~r n #:base 16 #:min-width width #:pad-string "0"))))

(define (engine-timing plan)
  (uds-timing (uds-flash-plan-p2-timeout-ms plan) (uds-flash-plan-p2-star-timeout-ms plan)))

(define (encode-routine-address-and-size address size #:address-length [address-length #f])
  (define address-size (or address-length (uds-address-length address)))
  (append (for/list ([shift (in-range (* (sub1 address-size) 8) -1 -8)])
            (bitwise-and (arithmetic-shift address (- shift)) #xFF))
          (for/list ([shift (in-range 24 -1 -8)])
            (bitwise-and (arithmetic-shift size (- shift)) #xFF))))

;; Adopt the ECU's maxNumberOfBlockLength from a positive 0x34 response,
;; but only when the response is plausible. The low nibble of the length
;; format identifier declares how many bytes carry the block length; a
;; declared length of zero (observed on a bench ECU answering
;; 50 40 00 00 0F FF) is bogus — adopting it would collapse the transfer
;; to 2-byte blocks, so the plan's value stands instead. A parsed block
;; length below 3 bytes cannot even carry SID + sequence + 1 data byte,
;; and is rejected for the same reason.
(define (adopt-max-block-length plan-max payload)
  (define size-bytes (bitwise-and (first payload) #x0F))
  (if (and (>= size-bytes 1)
           (<= size-bytes (length (rest payload))))
      (let ([raw (for/fold ([acc 0])
                           ([i (in-range 1 (add1 size-bytes))])
                   (bitwise-ior (arithmetic-shift acc 8) (list-ref payload i)))])
        (if (>= raw 3) (min plan-max (- raw 2)) plan-max))
      plan-max))

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
      (define req
        (uds-routine-control routine-start
                             (routine-step-routine-id step)
                             (routine-step-record step)))
      (wire-trace (format "routine ~a" did-hex) req)
      (define payload
        (with-handlers
            ([exn:fail:uds?
              (lambda (e)
                (fail! (format "~a routine 0x~a failed: ~a"
                               position-name did-hex (exn-message e))
                       (and (exn:fail:uds-nrc e)
                            (format "0x~a" (hex-up (exn:fail:uds-nrc e) 2)))))])
          (uds-require-positive client
                                req
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

(define flash-wire-trace? (getenv "FLASHPILOT_WIRE_TRACE"))
(define (wire-trace label req-vals)
  (when flash-wire-trace?
    (define parts
      (for/list ([v (in-list req-vals)])
        (if (bytes? v) (format "~a" (bytes->hex v)) (format "~a" v))))
    (eprintf "[wire] ~a req=[~a]\n" label (string-join parts " "))))

(define (flash-execute engine plan #:cancel [cancel #f] #:on-step [on-step #f])
  (define started (now-millis))
  (define steps '())
  (define total-bytes
    (for/sum ([seg (in-list (uds-flash-plan-segments plan))]) (length (uds-flash-segment-data seg))))
  (define client (flash-engine-client engine))

  (define (add-step! step)
    (set! steps (cons step steps))
    ;; Live progress surface: hosts and agents can stream the audited
    ;; workflow as it happens instead of waiting for the final result.
    (when on-step (on-step step)))
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

  ;; powerGuard enforcement: the plan declares bounds and a meter
  ;; provider; the engine polls during the destructive phase and aborts
  ;; permanently on out-of-band current — a physical safety event is
  ;; never blindly retried, operator investigates.
  (define guard (uds-flash-plan-power-guard plan))
  (define last-poll-box (box 0))
  (define poll-count-box (box 0))
  (define (poll-current!)
    (define provider (flash-power-guard-provider guard))
    (if (eq? (power-provider-kind provider) 'sim)
        (power-provider-ma provider)
        (let* ([out (open-output-string)]
               [exit-code
                (parameterize ([current-output-port out])
                  (apply system*/exit-code
                         (power-provider-command provider)
                         (power-provider-args provider)))]
               [text (string-trim (get-output-string out))]
               [ma (and (not (string-blank? text)) (string->number text))])
          (unless (and (real? ma) (>= exit-code 0))
            (fail-permanently!
             (format "powerGuard provider '~a' failed (exit ~a, output ~a) — safety is unverifiable, aborting."
                     (power-provider-command provider) exit-code (truncate-hex (string->bytes/utf-8 text) 24))))
          (inexact->exact (truncate ma)))))
  (define (check-power!)
    (when guard
      (define now (now-millis))
      (when (>= (- now (unbox last-poll-box)) (flash-power-guard-poll-ms guard))
        (set-box! last-poll-box now)
        (set-box! poll-count-box (add1 (unbox poll-count-box)))
        (define ma (poll-current!))
        (unless (and (>= ma (flash-power-guard-min-ma guard))
                     (<= ma (flash-power-guard-max-ma guard)))
          (fail-permanently!
           (format "powerGuard: ~a mA outside [~a, ~a] — aborting; physical safety events are never retried."
                   ma
                   (flash-power-guard-min-ma guard)
                   (flash-power-guard-max-ma guard)))))))

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
                 (constant-deriver-from-name deriver-name)
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

    ;; 3+4. Erase and download. Two shapes:
    ;;   default       - erase every segment, then download every segment.
    ;;   preEraseBytes - one linear session on a single segment: open it,
    ;;       stream the leading manifest bytes, erase, stream the rest.
    ;;       ECUs that validate a session manifest before flash is
    ;;       destroyed reject any erase that arrives first.
    (check-power!)
    (define pre (uds-flash-plan-pre-erase-bytes plan))
    (define addr-len (uds-flash-plan-address-length plan))
    (define max-block-payload (uds-flash-plan-max-block-payload plan))
    (define erase-poll (uds-flash-plan-erase-poll plan))
    (define erase-starts 0)
    (define erase-sw 0)
    (define download-sw (now-millis))
    (when (and pre (> (length (uds-flash-plan-segments plan)) 1))
      (fail! "preEraseBytes requires a single-segment plan (one linear download session)."))
    ;; TransferData sequence numbers are one byte wide; 0 is reserved, so
    ;; the counter cycles 1..255 (matches the bench ECU's expectation and
    ;; ota.rkt's reference stream).
    (define (next-seq s) (let ([n (add1 s)]) (if (> n 255) 1 n)))
    ;; Streams data[from, to) in max-block-payload chunks (power-guard
    ;; checked per chunk); returns the next block sequence number. A chunk
    ;; never crosses a plan-declared split offset (chunkSplitOffsets):
    ;; some ECUs section their download stream and reject - or silently
    ;; swallow - blocks that straddle a boundary, leaving the session
    ;; wedged with nothing but fake ACKs.
    (define split-offsets (uds-flash-plan-chunk-split-offsets plan))
    (define (stream-range data from to seq0)
      (let loop ([off from] [seq seq0])
        (if (>= off to)
            seq
            (let* ([next-split
                    (for/fold ([best to])
                              ([b (in-list split-offsets)]
                               #:when (and (> b off) (< b to)))
                      (min best b))]
                   [chunk-size (min (- to off) max-block-payload (- next-split off))]
                   [chunk (take (drop data off) chunk-size)])
              (check-power!)
              (uds-require-positive client
                                    (uds-transfer-data seq chunk)
                                    #:timing (engine-timing plan)
                                    #:cancel cancel)
              (loop (+ off chunk-size) (next-seq seq))))))
    (define (open-download-session! seg)
      ;; Tolerate a RequestDownload NRC: some ECUs reject the 0x34 at the
      ;; DCM layer and arm their session from the first manifest block
      ;; instead — the window transfer below drives that path. When the
      ;; request IS positive, adopt the ECU's maxNumberOfBlockLength.
      (define req34
        (uds-request-download (uds-flash-segment-address seg)
                              (length (uds-flash-segment-data seg))
                              #:address-length addr-len))
      (wire-trace "34" req34)
      (define payload
        (with-handlers
            ([exn:fail:uds?
              (lambda (e)
                (unless (eq? (exn:fail:uds-nrc e) #x13)
                  (raise e))
                #f)])
          (uds-require-positive client
                                req34
                                #:timing (engine-timing plan)
                                #:cancel cancel)))
      (when payload
        (when (< (length payload) 2)
          (fail! "RequestDownload response malformed."))
        (set! max-block-payload (adopt-max-block-length max-block-payload payload))))
    (define (erase-segment! seg)
      (define record
        (or (uds-flash-plan-erase-record plan)
            (encode-routine-address-and-size
             (uds-flash-segment-address seg)
             (length (uds-flash-segment-data seg))
             #:address-length addr-len)))
      (let erase-loop ([round 1])
        (wire-trace (format "FF00 round ~a" round)
                    (uds-routine-control routine-start
                                         (uds-flash-plan-erase-routine-id plan)
                                         record))
        (set! erase-starts (add1 erase-starts))
        (define response
          (uds-require-positive client
                                (uds-routine-control routine-start
                                                     (uds-flash-plan-erase-routine-id plan)
                                                     record)
                                #:timing (if erase-poll
                                             (uds-timing
                                              (erase-poll-round-timeout-ms erase-poll)
                                              (uds-flash-plan-p2-star-timeout-ms plan))
                                             (engine-timing plan))
                                #:cancel cancel))
        (define routine-id (bitwise-ior (arithmetic-shift (second response) 8) (third response)))
        (when (or (< (length response) 4)
                  (not (= (first response) routine-start))
                  (not (= routine-id (uds-flash-plan-erase-routine-id plan))))
          (fail! (format "Erase routine response mismatch (got ~a)." (bytes->hex response))))
        (when erase-poll
          ;; Payload after the SID echoes [kind, id-hi, id-lo, status].
          (define status (if (>= (length response) 4) (fourth response) #f))
          (cond
            [(and status (= status (erase-poll-status-byte erase-poll))) (void)]
            [(< round (erase-poll-max-rounds erase-poll)) (erase-loop (add1 round))]
            [else
             (fail! (format "Erase did not reach status 0x~a within ~a start(s) (last status ~a)."
                            (hex-up (erase-poll-status-byte erase-poll) 2)
                            (erase-poll-max-rounds erase-poll)
                            (if status (format "0x~a" (hex-up status 2)) "absent")))]))))
    (define (audit-erase!)
      (add-step! (flash-step-summary "erase"
                                     #t
                                     (if erase-poll
                                         (format "~a segment(s) erased via routine 0x~a in ~a start(s)."
                                                 (length (uds-flash-plan-segments plan))
                                                 (hex-up (uds-flash-plan-erase-routine-id plan) 4)
                                                 erase-starts)
                                         (format "~a segment(s) erased via routine 0x~a."
                                                 (length (uds-flash-plan-segments plan))
                                                 (hex-up (uds-flash-plan-erase-routine-id plan) 4)))
                                     (/ (- (now-millis) erase-sw) 1.0)
                                     #f)))

    (cond
      [pre
       ;; Manifest-first: one segment, one session, split around the erase.
       (define seg (first (uds-flash-plan-segments plan)))
       (define data (uds-flash-segment-data seg))
       (when (> pre (length data))
         (fail! (format "preEraseBytes ~a exceeds the image size ~a." pre (length data))))
       (open-download-session! seg)
       (define seq-after-window (stream-range data 0 pre #x01))
       (set! erase-starts 0)
       (erase-segment! seg)
       (audit-erase!)
       (stream-range data pre (length data) seq-after-window)
       (uds-require-positive client
                             (uds-request-transfer-exit)
                             #:timing (engine-timing plan)
                             #:cancel cancel)
       (add-step! (flash-step-summary "download"
                                      #t
                                      (format "segment @0x~a: ~a bytes, ~aB blocks, ~a byte(s) streamed pre-erase"
                                              (hex-up (uds-flash-segment-address seg) 8)
                                              (length data)
                                              max-block-payload
                                              pre)
                                      (/ (- (now-millis) download-sw) 1.0)
                                      #f))]
      [else
       ;; Default: erase every segment, then download every segment.
       (for ([seg (in-list (uds-flash-plan-segments plan))])
         (erase-segment! seg))
       (audit-erase!)
       (for ([seg (in-list (uds-flash-plan-segments plan))])
         (define sw (now-millis))
         (open-download-session! seg)
         (stream-range (uds-flash-segment-data seg) 0 (length (uds-flash-segment-data seg)) #x01)
         (uds-require-positive client
                               (uds-request-transfer-exit)
                               #:timing (engine-timing plan)
                               #:cancel cancel)
         (add-step! (flash-step-summary "download"
                                        #t
                                        (format "segment @0x~a: ~a bytes, ~aB blocks"
                                                (hex-up (uds-flash-segment-address seg) 8)
                                                (length (uds-flash-segment-data seg))
                                                max-block-payload)
                                        (/ (- (now-millis) sw) 1.0)
                                        #f)))])

    ;; 4b. powerGuard audit summary for the destructive phase.
    (when guard
      (add-step! (flash-step-summary
                  "power-guard"
                  #t
                  (format "~a poll(s) in-band [~a, ~a] mA."
                          (unbox poll-count-box)
                          (flash-power-guard-min-ma guard)
                          (flash-power-guard-max-ma guard))
                  (elapsed-ms)
                  #f)))

    ;; 5. Verify via CRC32 routine — the plan may pin an explicit
    ;; package-level CRC (ECUs whose CheckDataIntegrity compares a
    ;; packer-computed value rather than the byte-stream CRC).
    (check-power!)
    (let ([sw (now-millis)])
      (define pinned (uds-flash-plan-verify-crc32 plan))
      (define crc
        (if pinned
            (for/fold ([acc 0]) ([b (in-list pinned)])
              (bitwise-ior (arithmetic-shift acc 8) b))
            (crc32-compute (uds-flash-plan-segments plan))))
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
                                (format "0x~a" (hex-up (exn:fail:uds-nrc e) 2))))) ]
                 ;; A dropped link is "not ready yet", not a verdict: when
                 ;; the transport revives it, keep polling within the
                 ;; deadline. Without a revive hook the failure surfaces.
                 [(lambda (e)
                    (define revive (flash-engine-revive-link engine))
                    (and (exn:fail? e)
                         (not (exn:fail:uds? e))
                         revive
                         (revive e)))
                  (lambda (e) 'revived)])
              (uds-require-positive (engine-gate-client engine)
                                    (uds-read-did (post-reset-gate-did gate))
                                    #:timing (engine-timing plan)
                                    #:cancel cancel)))
          (cond
            [(eq? read-result 'revived)
             (when (> (now-millis) deadline)
               (fail! (format "Post-reset gate DID 0x~a never matched within ~a ms (link lost)."
                              (hex-up (post-reset-gate-did gate) 4)
                              (post-reset-gate-timeout-ms gate))))
             (poll)]
            [else
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
            [else (poll)])]))))

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
