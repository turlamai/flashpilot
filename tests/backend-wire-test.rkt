#lang racket/base

(require json rackunit racket/match racket/path racket/file
         rivet/backend rivet/protocol)

(define test-directory
  (or (current-load-relative-directory) (current-directory)))
(define backend-path
  (simplify-path (build-path test-directory ".." "app" "backend.rkt")))
(void (dynamic-require backend-path #f))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-thread (thread (lambda () (serve server-in server-out))))

(define (read-frame/timeout label)
  (define result (box #f))
  (define failure (box #f))
  (define reader
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (exception)
                                    (set-box! failure exception))])
         (set-box! result (read-frame client-in))))))
  (unless (sync/timeout 30 reader)
    (fail (format "timed out waiting for ~a" label)))
  (when (unbox failure) (raise (unbox failure)))
  (unbox result))

(define next-id 0)
(define collected-events '())
(define (call-rpc name . arguments)
  (set! next-id (add1 next-id))
  (define id next-id)
  (write-frame (frame message:request id (encode-value (cons name arguments)))
               client-out)
  (flush-output client-out)
  (let loop ()
    (define response (read-frame/timeout name))
    (match (frame-type response)
      [(== message:event)
       (set! collected-events
             (cons (decode-value (frame-payload response)) collected-events))
       (loop)]
      [(== message:response)
       (check-equal? (frame-id response) id)
       (values (decode-value (frame-payload response)) #f)]
      [(== message:error)
       (check-equal? (frame-id response) id)
       (values #f (decode-value (frame-payload response)))]
      [_ (loop)])))

(dynamic-wind
 void
 (lambda ()
   (define hello (read-frame/timeout "RVT1 hello"))
   (check-equal? (frame-type hello) message:hello)
   (check-equal? (decode-value (frame-payload hello))
                 (list "rivet" protocol-version))

   (define-values (status status-error) (call-rpc "bench-status"))
   (check-false status-error)
   (define status-json (string->jsexpr status))
   (check-equal? (hash-ref status-json 'product) "FlashPilot")
   (check-equal? (hash-ref status-json 'ready) #t)
   (check-equal? (hash-ref status-json 'mode) "simulator")
   (check-true (hash-has-key? status-json 'fixtures))

   (define-values (validation validation-error) (call-rpc "bench-validate"))
   (check-false validation-error)
   (define validation-json (string->jsexpr validation))
   (check-equal? (hash-ref validation-json 'ok) #t)
   (check-true (pair? (hash-ref validation-json 'checks)))

   (define-values (dtcs dtc-error) (call-rpc "dtc-read"))
   (check-false dtc-error)
   (check-equal? (hash-ref (string->jsexpr dtcs) 'ok) #t)


   ;; verify-plan: valid plan, segment file resolved relative to the plan.
   (define sim-plan
     (simplify-path (build-path test-directory ".." "examples" "plan.sim.json")))
   (define-values (verified verify-error) (call-rpc "verify-plan" (path->string sim-plan)))
   (check-false verify-error)
   (define verified-json (string->jsexpr verified))
   (check-equal? (hash-ref verified-json 'ok) #t)
   (check-equal? (hash-ref verified-json 'segments) 1)
   (check-equal? (hash-ref verified-json 'error) 'null)
   (check-true (string? (hash-ref verified-json 'fingerprint)))
   (define seg-detail (car (hash-ref verified-json 'segmentDetails)))
   (check-equal? (hash-ref seg-detail 'address) #x08000000)
   (check-equal? (hash-ref seg-detail 'source) "fw.bin")
   (check-true (> (hash-ref seg-detail 'bytes) 0))
   (check-equal? (hash-ref verified-json 'session) 2)

   ;; flash-plan: the simulated bench ECU executes the bundled plan; the
   ;; audited workflow comes back as JSON with the seven steps.
   (define-values (flashed flash-error) (call-rpc "flash-plan" (path->string sim-plan)))
   (check-false flash-error)
   (define flashed-json (string->jsexpr flashed))
   (check-equal? (hash-ref flashed-json 'ok) #t)
   (check-equal? (hash-ref flashed-json 'error) 'null)
   (check-true (> (hash-ref flashed-json 'bytes) 0))
   (check-equal? (map (lambda (s) (hash-ref s 'step)) (hash-ref flashed-json 'steps))
                 (list "identity" "diagnostic-session" "security-access" "erase"
                       "download" "verify" "ecu-reset"))
   (check-equal? (hash-ref flashed-json 'schema) "flashpilot.report/v1")
   (check-true (string? (hash-ref flashed-json 'startedAt)))
   (check-equal? (hash-ref flashed-json 'transport) "sim-uds (embedded bench)")
   ;; plan-progress events streamed the audited steps live, in order.
   (define progress-events
     (reverse
      (for/list ([e (in-list collected-events)]
                 #:when (and (pair? e) (equal? (car e) "plan-progress")))
        (string->jsexpr (cadr e)))))
   (check-equal? (length progress-events) 7)
   (check-equal? (map (lambda (e) (hash-ref e 'step)) progress-events)
                 (map (lambda (s) (hash-ref s 'step)) (hash-ref flashed-json 'steps)))
   (set! collected-events '())

   ;; verify-plan: unreadable file -> distinct recovery kind, no wire error.
   (define unreadable
     (path->string (build-path test-directory ".." "examples" "no-such-plan.json")))
   (define-values (unreadable-result unreadable-error) (call-rpc "verify-plan" unreadable))
   (check-false unreadable-error)
   (define unreadable-json (string->jsexpr unreadable-result))
   (check-equal? (hash-ref unreadable-json 'ok) #f)
   (check-equal? (hash-ref (hash-ref unreadable-json 'error) 'kind) "plan-unreadable")

   ;; verify-plan: structurally invalid plan -> plan-invalid.
   (define invalid-path (make-temporary-file "flashpilot-invalid-~a.json"))
   (with-output-to-file invalid-path
     (lambda ()
       (write-string
        "{\"segments\": [{\"address\": \"not-an-address\"}]}"))
     #:exists 'truncate/replace)
   (define-values (invalid-result invalid-error) (call-rpc "verify-plan" (path->string invalid-path)))
   (check-false invalid-error)
   (define invalid-json (string->jsexpr invalid-result))
   (check-equal? (hash-ref invalid-json 'ok) #f)
   (check-equal? (hash-ref (hash-ref invalid-json 'error) 'kind) "plan-invalid")
   (delete-file invalid-path)

   ;; verify-plan: segment file missing next to the plan -> segment-unavailable.
   (define missing-dir (make-temporary-directory))
   (define missing-path (build-path missing-dir "plan.json"))
   (with-output-to-file missing-path
     (lambda ()
       (write-string
        "{\"segments\": [{\"address\": \"0x08000000\", \"file\": \"no-such.bin\"}]}"))
     #:exists 'truncate/replace)
   (define-values (missing-result missing-error) (call-rpc "verify-plan" (path->string missing-path)))
   (check-false missing-error)
   (define missing-json (string->jsexpr missing-result))
   (check-equal? (hash-ref missing-json 'ok) #f)
   (check-equal? (hash-ref (hash-ref missing-json 'error) 'kind) "segment-unavailable"))
 (lambda () (kill-thread server-thread)))
