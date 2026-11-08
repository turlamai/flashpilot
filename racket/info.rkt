#lang info

(define collection 'multi)
(define version "0.2.0")
(define pkg-desc "FlashPilot: AI-native ECU flashing over UDS (CAN/DoIP/LIN)")
(define pkg-authors '(turlamai))
(define license 'AGPL-3.0)

(define deps
  '(["base" #:version "9.0"]))

(define build-deps
  '("rackunit-lib"))
