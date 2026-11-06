#lang racket/base

;; UDS-over-LIN tests: diagnostic framing, endpoint segmentation over the
;; simulated LIN segment, and the complete flash workflow through the
;; LIN channel (master tester + slave ECU).

(module+ test
  (require flashpilot/core/contracts
           flashpilot/diagnostics/channels/lin-uds-channel
           flashpilot/diagnostics/flash/engine
           flashpilot/diagnostics/flash/plans
           flashpilot/diagnostics/isotp/lin-endpoint
           flashpilot/diagnostics/isotp/lin-tp
           flashpilot/diagnostics/transport/simulated-can-bus
           flashpilot/diagnostics/uds/protocol
           racket/list
           rackunit)

  (test-case "lin diagnostic framing round trips"
    (define f (lin-encode-frame 'single #x01 '(#x22 #xF1 #x95)))
    (check-equal? (length f) 8)            ; NAD + PCI + 6-byte window
    (check-equal? f '(#x01 #x03 #x22 #xF1 #x95 #xFF #xFF #xFF))
    (define d (lin-try-decode f))
    (check-equal? (lin-frame-type d) 'single)
    (check-equal? (lin-frame-payload d) '(#x22 #xF1 #x95)))

  (test-case "lin first frame embeds the total length"
    (define f (lin-encode-first #x01 300 '(1 2 3 4)))
    (check-equal? (list-ref f 1) #x11)     ; 0x10 | (300 >> 8)
    (check-equal? (list-ref f 2) 44)       ; 300 & 0xFF
    (define d (lin-try-decode f))
    (check-equal? (lin-frame-type d) 'first)
    (check-equal? (lin-frame-sequence d) 300))

  (test-case "lin endpoint segments and reassembles over the simulated segment"
    (define bus (make-simulated-can-bus "lin-test"))
    (define tester-bus (make-sim-can-port-bus (simulated-can-bus-attach bus) "t"))
    (sim-can-port-bus-open! tester-bus)
    (define peer-bus (make-sim-can-port-bus (simulated-can-bus-attach bus) "p"))
    (sim-can-port-bus-open! peer-bus)
    (define master (make-lin-endpoint tester-bus #x01 #x3C #x3D (lin-options 1 0.002)))
    (define slave (make-lin-endpoint peer-bus #x01 #x3D #x3C (lin-options 1 0.002)))
    (define image (for/list ([i (in-range 40)]) (modulo i 256)))
    (define done (thread (lambda ()
      (lin-endpoint-send! master image)
      (define got (lin-endpoint-receive! slave))
      (check-equal? got image))))
    (unless (sync/timeout 10 done) (fail "LIN endpoint transfer timed out")))

  (test-case "flash workflow completes over LIN"
    (define channel (make-lin-uds-channel))
    (define image (for/list ([i (in-range 40)]) (modulo (* i 3) 256)))
    (define plan (uds-flash-plan (list (uds-flash-segment #x08000000 image #f))
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
                                 #f))
    (define result (lin-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    (check-equal? (uds-flash-result-total-bytes result) 40)
    (define step-names (map flash-step-summary-step (uds-flash-result-steps result)))
    (check-equal? step-names
                  '("diagnostic-session" "security-access" "erase" "download" "verify" "ecu-reset"))))
