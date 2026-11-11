#lang racket/base

;; UDS over LIN channel — the tester is the LIN master, the ECU a slave
;; node. Default transport is a simulated LIN segment (diagnostic frames
;; 0x3C/0x3D over the in-process bus) so the whole flash workflow runs
;; hardware-free; a hardware LIN adapter path is future work and says so.

(require json
         racket/class
         racket/format
         racket/list
         racket/string)

(require flashpilot/core/contracts
         (only-in flashpilot/diagnostics/flash/engine exn:fail:flash?)
         flashpilot/diagnostics/flash/engine
         flashpilot/diagnostics/flash/plans
         flashpilot/diagnostics/isotp/lin-endpoint
         flashpilot/diagnostics/isotp/lin-tp
         flashpilot/diagnostics/channels/sim-uds-channel
         flashpilot/diagnostics/transport/can-bus
         flashpilot/diagnostics/transport/simulated-can-bus
         flashpilot/diagnostics/uds/protocol)

(provide (struct-out lin-uds-channel)
         make-lin-uds-channel
         lin-channel-request
         lin-channel-flash
         lin-channel-health)

;; ---- channel ----------------------------------------------------------------

(struct lin-uds-channel
        (nad
         security-level
         key-deriver-name
         max-block-payload
         ecu-options
         lin-options
         mutex
         bus
         ecu-box
         channel-box))

(define (make-lin-uds-channel #:nad [nad #x01]
                              #:security-level [security-level #x01]
                              #:key-deriver-name [key-deriver-name "xor0x5a"]
                              #:max-block-payload [max-block-payload 1024]
                              #:ecu-options [ecu-options #f]
                              #:frame-gap-ms [frame-gap-ms 10])
  (lin-uds-channel nad
                   security-level
                   key-deriver-name
                   max-block-payload
                   (or ecu-options (default-uds-ecu-options))
                   (lin-options frame-gap-ms 0.002)
                   (make-semaphore 1)
                   (make-simulated-can-bus "sim-lin0")
                   (box #f)
                   (box #f)))

;; ---- simulated ECU side (slave node) ------------------------------------------

(struct lin-ecu (processor endpoint dispatch-thread))

(define (open-lin-ecu! c)
  (unless (unbox (lin-uds-channel-ecu-box c))
    (define processor (make-uds-processor (lin-uds-channel-ecu-options c)))
    (define ecu-port-bus
      (make-sim-can-port-bus (simulated-can-bus-attach (lin-uds-channel-bus c))
                             "lin-ecu"))
    (sim-can-port-bus-open! ecu-port-bus)
    (define endpoint
      (make-lin-endpoint ecu-port-bus
                         (lin-uds-channel-nad c)
                         lin-frame-slave-resp
                         lin-frame-master-req
                         (lin-uds-channel-lin-options c)))
    (define dispatch
      (thread
       (lambda ()
         (let loop ()
           (with-handlers ([exn:flashpilot:cancelled? (lambda (_) (void))])
             (define request (lin-endpoint-receive! endpoint))
             (define response (uds-processor-process! processor request))
             (when (and (>= (uds-server-response-delay-ms response) 0)
                        (not (null? (uds-server-response-response response))))
               (when (> (uds-server-response-delay-ms response) 0)
                 (sleep (/ (uds-server-response-delay-ms response) 1000.0)))
               (lin-endpoint-send! endpoint (uds-server-response-response response)))
             (loop))))))
    (set-box! (lin-uds-channel-ecu-box c) (lin-ecu processor endpoint dispatch))))

;; ---- tester side (master node) --------------------------------------------------

(struct lin-tester (endpoint client engine))

(define (open-lin-tester! c)
  (with-mutex*
   (lin-uds-channel-mutex c)
   (lambda ()
     (unless (unbox (lin-uds-channel-channel-box c))
       (open-lin-ecu! c)
       (define tester-port-bus
         (make-sim-can-port-bus (simulated-can-bus-attach (lin-uds-channel-bus c))
                                "lin-tester"))
       (sim-can-port-bus-open! tester-port-bus)
       (define endpoint
         (make-lin-endpoint tester-port-bus
                            (lin-uds-channel-nad c)
                            lin-frame-master-req
                            lin-frame-slave-resp
                            (lin-uds-channel-lin-options c)))
       (define client
         (make-uds-client (lambda (request cancel)
                            (lin-endpoint-send! endpoint request #:cancel cancel))
                          (lambda (cancel poll) (lin-endpoint-receive! endpoint #:cancel cancel))))
       (set-box! (lin-uds-channel-channel-box c)
                 (lin-tester endpoint client
                             (make-flash-engine client (make-key-derivers))))))))

(define (lin-tester-of c)
  (open-lin-tester! c)
  (unbox (lin-uds-channel-channel-box c)))

;; ---- public operations -----------------------------------------------------------

(define (lin-channel-request c request p2-ms p2-star-ms #:cancel [cancel #f])
  (define hex (bytes->hex request))
  (define t (lin-tester-of c))
  (with-handlers ([exn:fail:uds?
                   (lambda (e)
                     (uds-request-result #f
                                         #f
                                         hex
                                         #f
                                         (and (exn:fail:uds-nrc e)
                                              (nrc-name (exn:fail:uds-nrc e)))
                                         (exn-message e)))]
                  [exn:fail:lin?
                   (lambda (e)
                     (uds-request-result #f #f hex #f #f (exn-message e)))])
    (define response
      (uds-send (lin-tester-client t)
                request
                #:timing (uds-timing p2-ms p2-star-ms)
                #:cancel cancel))
    (if (uds-response-positive response)
        (uds-request-result #t #t hex (bytes->hex (uds-response-payload response)) #f #f)
        (uds-request-result #t #f hex #f (nrc-name (uds-response-nrc response)) #f))))

(define (lin-channel-flash c spec)
  (define t (lin-tester-of c))
  (with-handlers ([exn:fail:flash? (lambda (e) (exn:fail:flash-execution e))])
    (flash-execute (lin-tester-engine t) spec)))

(define (lin-channel-health c)
  (resource-health-result
   #t
   "LIN UDS channel is configured (simulated segment)."
   (hasheq "kind" "lin-uds"
           "nad" (format "0x~a" (~r (lin-uds-channel-nad c) #:base 16))
           "transport" "iso-tp/lin (simulated)")
   #f))
