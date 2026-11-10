#lang racket/base

;; Declarative flash plans: the portable, AI-authorable artifact at the
;; center of FlashPilot. A plan describes one complete UDS flashing
;; transaction — memory segments, session, security access, erase/verify
;; routines, transport timings, the expectedIdentity ECU gate — plus
;; hardening options (recovery strategy, in-programming power guard) and
;; the image fingerprint gate.

(require json
         racket/file
         racket/format
         racket/list
         racket/string)

(require flashpilot/core/contracts
         flashpilot/diagnostics/flash/image
         flashpilot/diagnostics/isotp/codec)

(provide (struct-out uds-flash-plan)
         (struct-out uds-flash-segment)
         (struct-out identity-check)
         (struct-out erase-poll)
         (struct-out routine-step)
         (struct-out post-reset-gate)
         (struct-out flash-power-guard)
         (struct-out power-provider)
         (struct-out uds-flash-hardening)
         uds-flash-hardening-plan
         uds-flash-hardening-expected-fingerprint
         flash-plan-fingerprint
         identity-json
         parse-chunk-split-offsets
         read-flash-plan-json
         read-segment-file)

(struct uds-flash-plan
        (segments max-block-payload
                  session
                  security-level
                  key-deriver
                  erase-routine-id
                  verify-routine-id
                  block-retries
                  p2-timeout-ms
                  p2-star-timeout-ms
                  expected-identity
                  erase-poll
                  routine-steps
                  post-reset-gate
                  on-fail
                  power-guard
                  address-length
                  pre-erase-bytes
                  verify-crc32
                  erase-record
                  chunk-split-offsets)
  #:transparent)
(struct uds-flash-segment (address data file) #:transparent)

;; One ECU identification gate entry: the DID to read (22 XX XX) and the
;; exact byte sequence the positive response must carry after the echoed
;; DID bytes.
(struct identity-check (did value) #:transparent)

;; Polled erase: slice-erase ECUs answer each erase routine-start with a
;; vendor status byte (in-progress vs done); the engine repeats the start
;; with the same address/size record until the byte reports done, at most
;; max-rounds rounds, each bounded by round-timeout-ms. Absent →
;; single-shot erase, exactly the historical behavior.
(struct erase-poll (status-byte max-rounds round-timeout-ms) #:transparent)

;; A vendor routine call at a fixed point of the flash sequence — the
;; declarative answer to prechecks (mechanics settling before erase) and
;; activations (arm the new image after verify). The engine requires a
;; positive response and records the bytes; vendor status semantics are
;; never interpreted.
(struct routine-step (at routine-id record timeout-ms) #:transparent)

(define routine-step-positions '("before-erase" "after-verify"))

;; routineSteps entries: { at, routineId, record?, timeoutMs? }. record is
;; even-length hex (default empty); timeoutMs > 0 (default: the plan's
;; p2TimeoutMs).
(define (parse-routine-steps raw)
  (unless (list? raw)
    (raise-validation "Flash plan routineSteps must be a list."))
  (for/list ([entry (in-list raw)])
    (unless (hash? entry)
      (raise-validation "Invalid routineSteps entry: expected an object."))
    (define at-raw (hash-ref entry 'at #f))
    (unless (and (string? at-raw) (member at-raw routine-step-positions))
      (raise-validation
       (format "Invalid routineSteps at '~a' (use before-erase or after-verify)." at-raw)))
    (define id-raw (hash-ref entry 'routineId #f))
    (define routine-id
      (cond
        [(exact-integer? id-raw) id-raw]
        [(and (string? id-raw) (string-prefix? (string-downcase id-raw) "0x"))
         (string->number (substring id-raw 2) 16)]
        [else #f]))
    (unless (and routine-id (exact-integer? routine-id) (<= 0 routine-id #xFFFF))
      (raise-validation
       (format "Invalid routineSteps routineId '~a' (use 0x0000..0xFFFF)." id-raw)))
    (define record-raw (hash-ref entry 'record #f))
    (define record
      (if record-raw
          (begin
            (unless (string? record-raw)
              (raise-validation "routineSteps record must be a hex string."))
            (hex-parse record-raw))
          '()))
    (define timeout-raw (hash-ref entry 'timeoutMs #f))
    (when (and timeout-raw
               (or (not (exact-integer? timeout-raw)) (not (> timeout-raw 0))))
      (raise-validation "routineSteps timeoutMs must be an integer > 0."))
    (routine-step (string->symbol at-raw) routine-id record timeout-raw)))

;; Post-reset confirmation gate: after EcuReset the engine polls one DID
;; until its exact bytes match — the ECU must prove it came back healthy
;; on the new image before the run reports success. Same value semantics
;; as expectedIdentity (exactly one of value / valueHex).
(struct post-reset-gate (did value timeout-ms interval-ms) #:transparent)

(define (parse-post-reset-gate raw)
  (unless (hash? raw)
    (raise-validation "Flash plan postResetGate must be an object."))
  (define did-raw (hash-ref raw 'did #f))
  (define did
    (cond
      [(exact-integer? did-raw) did-raw]
      [(and (string? did-raw) (string-prefix? (string-downcase did-raw) "0x"))
       (string->number (substring did-raw 2) 16)]
      [else #f]))
  (unless (and did (exact-integer? did) (<= 0 did #xFFFF))
    (raise-validation
     (format "Invalid postResetGate DID '~a' (use 0x0000..0xFFFF)." did-raw)))
  (define did-hex (~r did #:base 16))
  (define value-raw (hash-ref raw 'value #f))
  (define hex-raw (hash-ref raw 'valueHex #f))
  (define value
    (cond
      [(and value-raw hex-raw)
       (raise-validation
        (format "postResetGate DID 0x~a sets both value and valueHex." did-hex))]
      [(string? value-raw)
       (when (zero? (string-length value-raw))
         (raise-validation
          (format "postResetGate DID 0x~a has an empty value." did-hex)))
       (bytes->list (string->bytes/utf-8 value-raw))]
      [(string? hex-raw) (hex-parse hex-raw)]
      [else
       (raise-validation
        (format "postResetGate DID 0x~a needs value (UTF-8) or valueHex (hex)." did-hex))]))
  (define timeout-ms (hash-ref raw 'timeoutMs #f))
  (unless (and (exact-integer? timeout-ms) (> timeout-ms 0))
    (raise-validation "postResetGate timeoutMs must be an integer > 0."))
  (define interval-raw (hash-ref raw 'intervalMs #f))
  (define interval-ms (or interval-raw 500))
  (unless (and (exact-integer? interval-ms) (> interval-ms 0))
    (raise-validation "postResetGate intervalMs must be an integer > 0."))
  (post-reset-gate did value timeout-ms interval-ms))

;; Shared JSON shape for configured identity gates (CLI verify, bench RPC).
(define (identity-json checks)
  (for/list ([c (in-list checks)])
    (hasheq 'did (identity-check-did c)
            'valueHex (bytes->hex (identity-check-value c)))))

(struct flash-power-guard (min-ma max-ma poll-ms provider) #:transparent)

;; The bench-supply meter behind a powerGuard. `sim` reports a constant
;; (CI and benches); `command` runs an external vendor script per poll and
;; parses the live current in mA from its stdout — vendor code stays
;; outside the engine, the keyDeriver command: pattern.
(struct power-provider (kind command args ma) #:transparent)
(struct uds-flash-hardening (plan expected-fingerprint data-length)
  #:transparent)

;; Deterministic FNV-1a over addresses + lengths + data, in plan order.
;; 16 hex chars — a fingerprint, not a crypto hash.
(define (flash-plan-fingerprint segments)
  (define h-box (box #xcbf29ce484222325))
  (define (mix byte)
    (set-box! h-box
              (bitwise-and #xFFFFFFFFFFFFFFFF
                           (* (bitwise-and #xFFFFFFFFFFFFFFFF
                                           (bitwise-xor (unbox h-box) byte))
                              #x100000001b3))))
  (for ([seg (in-list segments)])
    (mix (bitwise-and (uds-flash-segment-address seg) #xFF))
    (for ([shift (in-range 8 64 8)])
      (mix (bitwise-and (arithmetic-shift (uds-flash-segment-address seg)
                                          (- shift))
                        #xFF)))
    (define data (uds-flash-segment-data seg))
    (mix (length data))
    (for ([b (in-list data)]) (mix b)))
  (substring (~r (unbox h-box) #:base 16 #:min-width 16 #:pad-string "0") 0 16))

;; Parses a plan JSON document into plan + hardening. The plan struct is
;; the engine-facing part (including the expectedIdentity gate the engine
;; enforces at runtime); hardening carries onFail / powerGuard /
;; expectedFingerprint.

;; expectedIdentity entries: { did, value (UTF-8) | valueHex }. Exactly one
;; value form per entry; DID is 16-bit; empty expectations are rejected —
;; an empty byte sequence can never be what an author means.
(define (parse-identity-entries raw)
  (unless (list? raw)
    (raise-validation "Flash plan expectedIdentity must be a list."))
  (for/list ([entry (in-list raw)])
    (unless (hash? entry)
      (raise-validation "Invalid expectedIdentity entry: expected an object."))
    (define did-raw (hash-ref entry 'did #f))
    (define did
      (cond
        [(exact-integer? did-raw) did-raw]
        [(and (string? did-raw) (string-prefix? (string-downcase did-raw) "0x"))
         (string->number (substring did-raw 2) 16)]
        [else #f]))
    (unless (and did (exact-integer? did) (<= 0 did #xFFFF))
      (raise-validation
       (format "Invalid expectedIdentity DID '~a' (use 0x0000..0xFFFF)." did-raw)))
    (define did-hex (~r did #:base 16))
    (define value-raw (hash-ref entry 'value #f))
    (define hex-raw (hash-ref entry 'valueHex #f))
    (define value
      (cond
        [(and value-raw hex-raw)
         (raise-validation
          (format "expectedIdentity DID 0x~a sets both value and valueHex." did-hex))]
        [(string? value-raw)
         (when (zero? (string-length value-raw))
           (raise-validation
            (format "expectedIdentity DID 0x~a has an empty value." did-hex)))
         (bytes->list (string->bytes/utf-8 value-raw))]
        [(string? hex-raw) (hex-parse hex-raw)]
        [else
         (raise-validation
          (format "expectedIdentity DID 0x~a needs value (UTF-8) or valueHex (hex)." did-hex))]))
    (identity-check did value)))

;; erasePoll entries: all three fields required when the object is present
;; — an explicit plan is the reviewable artifact, no hidden defaults.
(define (parse-erase-poll raw)
  (unless (hash? raw)
    (raise-validation "Flash plan erasePoll must be an object."))
  (define status-raw (hash-ref raw 'statusByte #f))
  (define status-byte
    (cond
      [(exact-integer? status-raw) status-raw]
      [(and (string? status-raw) (string-prefix? (string-downcase status-raw) "0x"))
       (string->number (substring status-raw 2) 16)]
      [else #f]))
  (unless (and status-byte (exact-integer? status-byte) (<= 0 status-byte 255))
    (raise-validation
     (format "Invalid erasePoll statusByte '~a' (use 0x00..0xFF)." status-raw)))
  (define max-rounds (hash-ref raw 'maxRounds #f))
  (unless (and (exact-integer? max-rounds) (>= max-rounds 1))
    (raise-validation "erasePoll maxRounds must be an integer >= 1."))
  (define round-timeout (hash-ref raw 'roundTimeoutMs #f))
  (unless (and (exact-integer? round-timeout) (> round-timeout 0))
    (raise-validation "erasePoll roundTimeoutMs must be an integer > 0."))
  (erase-poll status-byte max-rounds round-timeout))

;; Parses powerGuard: bounds, poll interval and the required meter
;; provider. Enforcement is real measurements or nothing — a plan never
;; silently measures with a fake.
(define (parse-power-guard guard-raw)
  (unless (hash? guard-raw)
    (raise-validation "Flash plan powerGuard must be an object."))
  (define provider-raw (hash-ref guard-raw 'provider #f))
  (unless (hash? provider-raw)
    (raise-validation
     "powerGuard requires a provider: {\"kind\": \"sim\", \"ma\": N} or {\"kind\": \"command\", \"command\": \"./bench-power\"}."))
  (define kind-raw (hash-ref provider-raw 'kind #f))
  (define kind
    (cond
      [(equal? kind-raw "sim") 'sim]
      [(equal? kind-raw "command") 'command]
      [else
       (raise-validation
        (format "powerGuard provider kind must be 'sim' or 'command' (got '~a')." kind-raw))]))
  (define command-raw (hash-ref provider-raw 'command #f))
  (when (and (eq? kind 'command)
             (not (and (string? command-raw) (not (string-blank? command-raw)))))
    (raise-validation "powerGuard command provider needs a non-empty command."))
  (define args-raw (hash-ref provider-raw 'args '()))
  (unless (and (list? args-raw) (andmap string? args-raw))
    (raise-validation "powerGuard provider args must be a list of strings."))
  (define ma-raw (hash-ref provider-raw 'ma 500))
  (unless (and (exact-integer? ma-raw) (>= ma-raw 0))
    (raise-validation "powerGuard sim provider ma must be an integer >= 0."))
  (define min-ma (hash-ref guard-raw 'minMa #f))
  (define max-ma (hash-ref guard-raw 'maxMa #f))
  (unless (and (exact-integer? min-ma) (exact-integer? max-ma))
    (raise-validation "powerGuard minMa and maxMa must be integers."))
  (define poll-ms (or (hash-ref guard-raw 'pollMs #f) 200))
  (unless (and (exact-integer? poll-ms) (> poll-ms 0))
    (raise-validation "powerGuard pollMs must be an integer > 0."))
  (flash-power-guard
   min-ma max-ma poll-ms
   (power-provider kind
                   (and (eq? kind 'command) command-raw)
                   args-raw
                   ma-raw)))

;; addressLength: fixed-width address encoding for RequestDownload and
;; the routine records. Default (#f): minimal encoding per address value.
;; Some ECUs declare an exact format (typically 4-byte) and reject
;; shorter encodings.
(define (parse-address-length raw)
  (cond
    [(not raw) #f]
    [(and (exact-integer? raw) (<= 1 raw 8)) raw]
    [else
     (raise-validation
      (format "addressLength must be an integer 1..8 (got '~a')." raw))]))

;; eraseRecord: explicit hex bytes for the erase routine record. Default
;; (#f): the engine encodes (address, size) per the address length. Some
;; ECUs expect a fixed legacy payload (e.g. 8 zero bytes) and validate
;; the record at the DCM layer.
;; preEraseBytes: transfer exactly this many leading image bytes (a
;; session manifest the ECU validates) after RequestDownload but BEFORE
;; the erase; the remaining bytes stream after the erase completes.
;; Requires a single segment - the split only makes sense for one linear
;; download session.
;; verifyCrc32: explicit package-level CRC for the verify routine — for
;; ECUs whose CheckDataIntegrity expects a package CRC that is not the
;; engine's own byte-stream computation (e.g. a header-fields CRC the
;; packer computes). Hex string, parsed big-endian into the 4-byte
;; routine record. Default (#f): engine-computed CRC32 over segments.
(define (parse-verify-crc32 raw)
  (cond
    [(not raw) #f]
    [(and (string? raw) (string-prefix? (string-downcase raw) "0x"))
     (define b (hex-parse (substring raw 2)))
     (unless (= (length b) 4)
       (raise-validation
        (format "verifyCrc32 must be exactly 4 bytes (got ~a)." (length b))))
     b]
    [else
     (raise-validation "verifyCrc32 must be a 0x-prefixed 4-byte hex string.")]))

(define (parse-pre-erase-bytes raw)
  (cond
    [(not raw) #f]
    [(and (exact-integer? raw) (> raw 0)) raw]
    [else
     (raise-validation
      (format "preEraseBytes must be an integer > 0 (got '~a')." raw))]))

;; Payload-stream offsets a TransferData block must not cross. Some ECUs
;; split their download stream into sections (app / data / cal) and
;; reject - or worse, silently swallow - a block that straddles one.
;; Offsets are segment-absolute (0 = first byte of the segment data) and
;; accept integers or 0x-prefixed hex strings.
(define (parse-chunk-split-offsets raw)
  (cond
    [(not raw) '()]
    [(list? raw)
     (for/list ([v (in-list raw)])
       (cond
         [(exact-integer? v) v]
         [(and (string? v) (string-prefix? (string-downcase v) "0x"))
          (or (string->number (substring v 2) 16)
              (raise-validation (format "Invalid chunkSplitOffsets entry '~a'." v)))]
         [(and (string? v) (string->number v)) (string->number v)]
         [else
          (raise-validation
           (format "chunkSplitOffsets entries must be integers (got '~a')." v))]))]
    [else
     (raise-validation "chunkSplitOffsets must be a list of offsets.")]))

(define (read-flash-plan-json text)
  (define doc
    (with-handlers ([exn:fail? (lambda (e)
                                 (raise-validation (format "Invalid flash plan JSON: ~a"
                                                           (exn-message e))))])
      (read-json (open-input-string text))))
  (unless (hash? doc)
    (raise-validation "Invalid flash plan JSON: expected an object."))
  (define segments-raw (hash-ref doc 'segments #f))
  (define segments
    (if (list? segments-raw)
        (for/list ([seg (in-list segments-raw)])
          (unless (hash? seg)
            (raise-validation "Invalid flash plan segment: expected an object."))
          (define (address-value v)
            (cond
              [(exact-integer? v) v]
              [(and (string? v) (string-prefix? (string-downcase v) "0x"))
               (or (string->number (substring v 2) 16)
                   (raise-validation (format "Invalid segment address '~a'." v)))]
              [(string? v)
               (or (string->number v)
                   (raise-validation (format "Invalid segment address '~a'." v)))]
              [else (raise-validation (format "Invalid segment address '~a'." v))]))
          (uds-flash-segment
           (address-value
            (hash-ref seg
                      'address
                      (lambda () (raise-validation "Flash plan segment is missing 'address'."))))
           (let ([data (hash-ref seg 'data #f)])
             (cond
               [(string? data) (hex-parse data)]
               [(list? data) (map (lambda (x) (if (exact-integer? x) x 0)) data)]
               [else #f]))
           (hash-ref seg 'file #f)))
        '()))
  (define on-fail-raw (hash-ref doc 'onFail #f))
  (define on-fail
    (cond
      [(not on-fail-raw) #f]
      [(member on-fail-raw '("retry" "resetAndRetry") string-ci=?)
       => (lambda (m) (string->symbol (first m)))]
      [else
       (raise-validation
        (format "Flash plan onFail must be 'retry' or 'resetAndRetry' (got '~a')." on-fail-raw))]))
  (define power-guard
    (and (hash-ref doc 'powerGuard #f)
         (parse-power-guard (hash-ref doc 'powerGuard #f))))
  (define plan
    (uds-flash-plan segments
                    (or (hash-ref doc 'maxBlockPayload #f) 1024)
                    (or (hash-ref doc 'session #f) #x02)
                    (hash-ref doc 'securityLevel #f)
                    (hash-ref doc 'keyDeriver #f)
                    (or (hash-ref doc 'eraseRoutineId #f) #xFF00)
                    (or (hash-ref doc 'verifyRoutineId #f) #xFF01)
                    (or (hash-ref doc 'blockRetries #f) 0)
                    (or (hash-ref doc 'p2TimeoutMs #f) 1000)
                    (or (hash-ref doc 'p2StarTimeoutMs #f) 10000)
                    (let ([raw (hash-ref doc 'expectedIdentity #f)])
                      (if raw (parse-identity-entries raw) '()))
                    (let ([raw (hash-ref doc 'erasePoll #f)])
                      (and raw (parse-erase-poll raw)))
                    (let ([raw (hash-ref doc 'routineSteps #f)])
                      (if raw (parse-routine-steps raw) '()))
                    (let ([raw (hash-ref doc 'postResetGate #f)])
                      (and raw (parse-post-reset-gate raw)))
                    on-fail
                    power-guard
                    (parse-address-length (hash-ref doc 'addressLength #f))
                    (parse-pre-erase-bytes (hash-ref doc 'preEraseBytes #f))
                    (parse-verify-crc32 (hash-ref doc 'verifyCrc32 #f))
                    (let ([raw (hash-ref doc 'eraseRecord #f)])
                      (and raw (hex-parse raw)))
                    (parse-chunk-split-offsets (hash-ref doc 'chunkSplitOffsets #f))))
  ;; dataLength opts the transport into CAN FD (8 = classic; any other
  ;; value snaps up to the nearest legal FD length). DoIP ignores it.
  (define data-length
    (let ([v (hash-ref doc 'dataLength #f)])
      (if v (can-fd-next-dlen v) classic-data-length)))
  (uds-flash-hardening plan
                       (hash-ref doc 'expectedFingerprint #f) data-length))

(define (read-segment-file file base-directory)
  (when (or (not file) (string-blank? file))
    (raise-validation "Flash plan segment has no data and no file reference."))
  (define path
    (if (or (absolute-path? file) (regexp-match? #rx"^[A-Za-z]:" file))
        file
        (path->string (build-path base-directory file))))
  (unless (file-exists? path)
    (raise-validation (format "Flash plan segment file not found: ~a" path)))
  (file->bytes path))
