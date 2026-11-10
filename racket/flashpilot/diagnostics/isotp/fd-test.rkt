#lang racket/base

;; CAN FD tests: codec frame forms at FD data lengths, an ISO-TP endpoint
;; transfer over the simulated bus at dlen 64, and a full flash workflow
;; through the simulated channel with data-length 64 on both sides.

(module+ test
  (require flashpilot/core/contracts
           flashpilot/diagnostics/channels/sim-uds-channel
           flashpilot/diagnostics/flash/engine
           flashpilot/diagnostics/flash/plans
           flashpilot/diagnostics/isotp/codec
           flashpilot/diagnostics/isotp/endpoint
           flashpilot/diagnostics/transport/simulated-can-bus
           flashpilot/diagnostics/transport/socketcan
           flashpilot/diagnostics/uds/protocol
           racket/list
           rackunit)

  (define (byte-list n) (for/list ([i (in-range n)]) (modulo (* i 7) 256)))

  (test-case "socketcan wire codec round trips classic and FD frames"
    (define classic (can-frame #x7E0 #f '(1 2 3)))
    (define decoded (can-frame-try-decode (can-frame-encode classic)))
    (check-equal? decoded classic)
    (define fd (can-frame #x18EF0102 #t (for/list ([i (in-range 48)]) i)))
    (define fd-buf (canfd-frame-encode fd))
    (check-equal? (bytes-length fd-buf) 72)
    (check-equal? (can-frame-try-decode fd-buf) fd)
    (check-equal? (can-frame-try-decode (canfd-frame-encode
                                          (can-frame #x123 #f (for/list ([i (in-range 12)]) i))))
                  (can-frame #x123 #f (for/list ([i (in-range 12)]) i))))

  (test-case "can-fd-next-dlen snaps to legal FD lengths"
    (check-equal? (can-fd-next-dlen 8) 8)
    (check-equal? (can-fd-next-dlen 9) 12)
    (check-equal? (can-fd-next-dlen 33) 48)
    (check-equal? (can-fd-next-dlen 64) 64)
    (check-exn exn:fail? (lambda () (can-fd-next-dlen 65))))

  (test-case "FD single frame: short, escaped, and over-limit"
    ;; 1..7 short form, identical to classic
    (check-equal? (encode-single '(#x11 #x22) 64)
                  (append '(#x02 #x11 #x22) (make-list 61 0)))
    ;; 8..62: the standard FD escape [0x00][DL]
    (define payload (byte-list 10))
    (define frame (encode-single payload 64))
    (check-equal? (list-ref frame 0) #x00)
    (check-equal? (list-ref frame 1) 10)
    (check-equal? (take (drop frame 2) 10) payload)
    (check-equal? (length frame) 64)
    (check-exn exn:fail? (lambda () (encode-single (byte-list 63) 64))))

  (test-case "FD decode accepts the escaped single frame"
    (define payload (byte-list 10))
    (define frame (encode-single payload 64))
    (define decoded (try-decode-frame frame #:fd? #t))
    (check-true (isotp-frame? decoded))
    (check-equal? (isotp-frame-type decoded) 'single)
    (check-equal? (isotp-frame-payload decoded) payload)
    ;; classic decoder must not be offered FD frames (12-bit escape form)
    (check-false (try-decode-frame frame)))

  (test-case "FD first frame carries dlen-2 bytes, escape carries dlen-6"
    (define small (byte-list 100))
    (define ff (encode-first-prefix small 64))
    (check-equal? (length ff) 64)
    (check-equal? (list-ref ff 0) #x10)
    ;; payload length 100 in the PCI low byte, 62 data bytes follow
    (check-equal? (take (drop ff 2) 62) (take small 62))
    (define big (byte-list 5000))
    (define ffx (encode-first-prefix big 64))
    (check-equal? (list-ref ffx 0) #x10)
    (check-equal? (list-ref ffx 1) #x00)
    (check-equal? (take (drop ffx 6) 58) (take big 58)))

  (test-case "FD consecutive frames chunk at dlen-1"
    (define chunk (byte-list 70))
    (define cf (encode-consecutive 1 chunk 64))
    (check-equal? (length cf) 64)
    (check-equal? (list-ref cf 0) #x21)
    (check-equal? (length (drop cf 1)) 63))

  (test-case "ISO-TP endpoint transfers 300 bytes at dlen 64"
    (define bus (make-simulated-can-bus))
    (define opts (isotp-options 0 0 1000 0.002 64))
    (define tester-bus (make-sim-can-port-bus (simulated-can-bus-attach bus) "tester"))
    (sim-can-port-bus-open! tester-bus)
    (define tester
      (make-isotp-endpoint tester-bus #x7E0 #x7E8 opts))
    ;; the peer answers each request with a 300-byte payload in FD frames
    (define peer-bus (make-sim-can-port-bus (simulated-can-bus-attach bus) "peer"))
    (sim-can-port-bus-open! peer-bus)
    (define peer (make-isotp-endpoint peer-bus #x7E8 #x7E0 opts))
    (define responder
      (thread (lambda ()
                (let loop ()
                  (define request (isotp-endpoint-receive! peer))
                  (isotp-endpoint-send! peer (byte-list 300))
                  (loop)))))
    (isotp-endpoint-send! tester '(#x22 #xF1 #x95))
    (define response (isotp-endpoint-receive! tester))
    (check-equal? (length response) 300)
    (check-equal? response (byte-list 300))
    (kill-thread responder))

  (test-case "flash workflow completes over CAN FD (data-length 64)"
    (define channel (make-sim-uds-channel #:data-length 64))
    (define image (byte-list 300))
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
                                 #f
                                 #f
                                 #f
                                 #f
                                 #f
                                 #f
                                 #f
                                 '()))
    (define result (sim-channel-flash channel plan))
    (check-true (uds-flash-result-ok result))
    (check-equal? (uds-flash-result-total-bytes result) 300)
    (define step-names (map flash-step-summary-step (uds-flash-result-steps result)))
    (check-equal? step-names
                  '("diagnostic-session" "security-access" "erase" "download" "verify" "ecu-reset"))
    (check-true (equal? (uds-processor-received-image
                         (simulated-uds-ecu-processor (unbox (sim-uds-channel-ecu-box channel))))
                        image))))
