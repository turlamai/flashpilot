#lang racket/base

;; Tests: the support matrix stays honest — every entry carries an
;; evidence level from the fixed enum, and the known-unfinished corners
;; (PCAN FD, hardware LIN) are labeled planned, not silent.

(module+ test
  (require rackunit
           racket/file
           racket/string)

  (require flashpilot/diagnostics/support-matrix)

  (test-case "every entry carries an evidence level from the enum"
    (for ([e (in-list (support-entries))])
      (check-not-false (member (support-entry-evidence e) evidence-levels) 
                  (format "~a has an unknown evidence level"
                          (support-entry-transport e)))
      (check-true (non-empty-string? (string-trim (support-entry-notes e))))))

  (test-case "unverified corners are labeled planned, never silent"
    (define names (map support-entry-transport (support-entries)))
    (check-not-false (member "pcan-fd" names))
    (check-not-false (member "lin-hardware" names))
    (for ([e (in-list (support-entries))]
          #:when (member (support-entry-transport e) '("pcan-fd" "lin-hardware")))
      (check-equal? (support-entry-evidence e) "planned")))

  (test-case "simulated CI evidence exists for FD and LIN"
    (for ([e (in-list (support-entries))]
          #:when (member (support-entry-transport e) '("socketcan-fd" "lin-simulated")))
      (check-equal? (support-entry-evidence e) "ci-simulated")))

  (test-case "the hardware-in-loop claim is scoped to the reproduced transport"
    (define hil
      (for/list ([e (in-list (support-entries))]
                 #:when (equal? (support-entry-evidence e) "hardware-in-loop verified"))
        e))
    ;; The DoIP entry carries the only hardware claim, and its notes name
    ;; the reproduction evidence (report issue, engine SHA, findings).
    (check-equal? (map support-entry-transport hil) '("doip"))
    (define notes (support-entry-notes (car hil)))
    (check-true (regexp-match? #rx"issue #4" notes))
    (check-true (regexp-match? #px"[0-9a-f]{7}" notes)))

  (test-case "transports-json is deterministic and complete"
    (define json (transports-json))
    (check-equal? (length json) (length (support-entries)))
    (check-true (andmap hash? json))
    (check-not-false (andmap (lambda (h) (hash-ref h 'evidence #f)) json))))
