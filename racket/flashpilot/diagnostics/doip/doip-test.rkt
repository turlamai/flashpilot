#lang racket/base

;; DoIP channel tests: the reconnect policy against a simulated DoIP
;; entity that takes its TCP link down on EcuReset and refuses
;; connections for a configurable window — the model of an ECU rebooting
;; into a boot loader that verifies images before it talks again.

(module+ test
  (require flashpilot/core/contracts
           flashpilot/diagnostics/doip/doip
           flashpilot/diagnostics/flash/plans
           racket/list
           racket/string
           rackunit)

  (define test-image
    (for/list ([i (in-range 300)])
      (modulo (* i 7) 256)))

  ;; A flash plan ending in a post-reset gate: after EcuReset the ECU must
  ;; answer the 0xFD00 "ready" DID — which, with the link dropped by the
  ;; reset, is only reachable through a reconnect.
  (define (gate-plan)
    (uds-flash-plan (list (uds-flash-segment #x08000000 test-image #f))
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
                    (post-reset-gate #xFD00
                                     (bytes->list (string->bytes/utf-8 "ready"))
                                     8000
                                     200)
                    #f
                    #f
                    #f
                    #f
                    #f))

  (test-case "doip channel reconnects after a reset drops the link"
    (define server
      (start-simulated-doip-server #:close-on-reset? #t
                                   #:refuse-seconds 3
                                   #:enable-discovery #f))
    (define port (simulated-doip-server-listen-port server))
    (define channel
      (make-doip-uds-channel "127.0.0.1" port #x0E00 #x0E10
                             #:reconnect-attempts 8
                             #:reconnect-delay-ms 500))
    (define result (doip-uds-channel-flash channel (gate-plan)))
    (unless (uds-flash-result-ok result)
      (displayln (format "reconnect-path failure: ~a" (uds-flash-result-error result))))
    (check-true (uds-flash-result-ok result))
    (check-equal? (last (map flash-step-summary-step (uds-flash-result-steps result)))
                  "post-reset-gate")
    ;; The reset dropped the link at least once and the channel healed it.
    (check-true (>= (doip-uds-channel-reconnect-count channel) 1))
    (simulated-doip-server-dispose! server))

  (test-case "exhausted reconnect surfaces the connection error honestly"
    (define server
      (start-simulated-doip-server #:close-on-reset? #t
                                   #:refuse-seconds 120
                                   #:enable-discovery #f))
    (define port (simulated-doip-server-listen-port server))
    (define channel
      (make-doip-uds-channel "127.0.0.1" port #x0E00 #x0E10
                             #:reconnect-attempts 2
                             #:reconnect-delay-ms 200))
    (define result (doip-uds-channel-flash channel (gate-plan)))
    (check-false (uds-flash-result-ok result))
    ;; The ECU stays down for the whole window: the gate cannot pass and
    ;; the failure names the transport cause, not a UDS guess.
    (check-true
     (or (string-contains? (uds-flash-result-error result) "closed by peer")
         (string-contains? (uds-flash-result-error result) "refused")
         (string-contains? (uds-flash-result-error result) "connection")
         (string-contains? (uds-flash-result-error result) "DoIP")))
    (simulated-doip-server-dispose! server))

  (test-case "reconnect disabled keeps the historical stop-at-error behavior"
    (define server
      (start-simulated-doip-server #:close-on-reset? #t
                                   #:refuse-seconds 120
                                   #:enable-discovery #f))
    (define port (simulated-doip-server-listen-port server))
    (define channel (make-doip-uds-channel "127.0.0.1" port #x0E00 #x0E10))
    (define result (doip-uds-channel-flash channel (gate-plan)))
    (check-false (uds-flash-result-ok result))
    (check-equal? (doip-uds-channel-reconnect-count channel) 0)
    (simulated-doip-server-dispose! server))
)
