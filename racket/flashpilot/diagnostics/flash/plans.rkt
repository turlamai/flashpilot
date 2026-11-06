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
         (struct-out flash-power-guard)
         (struct-out uds-flash-hardening)
         uds-flash-hardening-plan
         uds-flash-hardening-on-fail
         uds-flash-hardening-power-guard
         uds-flash-hardening-expected-fingerprint
         flash-plan-fingerprint
         identity-json
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
                  erase-poll)
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

;; Shared JSON shape for configured identity gates (CLI verify, bench RPC).
(define (identity-json checks)
  (for/list ([c (in-list checks)])
    (hasheq 'did (identity-check-did c)
            'valueHex (bytes->hex (identity-check-value c)))))

(struct flash-power-guard (min-ma max-ma poll-ms) #:transparent)
(struct uds-flash-hardening (plan on-fail power-guard expected-fingerprint data-length)
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
                      (and raw (parse-erase-poll raw)))))
  (define on-fail-raw (hash-ref doc 'onFail #f))
  (define on-fail
    (cond
      [(not on-fail-raw) #f]
      [(member on-fail-raw '("retry" "resetAndRetry") string-ci=?)
       => (lambda (m) (string->symbol (first m)))]
      [else
       (raise-validation
        (format "Flash plan onFail must be 'retry' or 'resetAndRetry' (got '~a')." on-fail-raw))]))
  (define guard-raw (hash-ref doc 'powerGuard #f))
  (define power-guard
    (and guard-raw
         (begin
           (unless (hash? guard-raw)
             (raise-validation "Flash plan powerGuard must be an object."))
           (flash-power-guard
            (hash-ref guard-raw 'minMa #f)
            (hash-ref guard-raw 'maxMa #f)
            (or (hash-ref guard-raw 'pollMs #f) 200)))))
  ;; dataLength opts the transport into CAN FD (8 = classic; any other
  ;; value snaps up to the nearest legal FD length). DoIP ignores it.
  (define data-length
    (let ([v (hash-ref doc 'dataLength #f)])
      (if v (can-fd-next-dlen v) classic-data-length)))
  (uds-flash-hardening plan on-fail power-guard
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
