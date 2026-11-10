#lang racket/base

;; The support matrix as code: one machine-readable record of every
;; transport/adapter subset with its evidence level, consumed by the CLI
;; (`flashpilot transports`) so the matrix cannot rot away from reality.
;;
;; Evidence levels are honest by construction:
;;   "ci-simulated"            — the full loop runs against the simulated
;;                               ECU in CI on every push
;;   "implemented-unverified"  — code ships and is unit-tested where
;;                               possible, but no real adapter/ECU has
;;                               confirmed it
;;   "hardware-in-loop verified" — a versioned adapter + reference-ECU
;;                               reproduction report exists (the issue #4
;;                               gate); vendor identity stays redacted
;;   "planned"                 — not implemented; named so agents and
;;                               users never guess
;;
;; Nothing in this matrix claims production flashing reliability across
;; arbitrary ECUs; the hardware-in-loop level is scoped to the exact
;; adapter/ECU class named in its reproduction report.

(require racket/contract
         racket/list
         racket/string)

(provide support-entries
         support-entry?
         support-entry-transport
         support-entry-platform
         support-entry-evidence
         support-entry-notes
         evidence-levels
         transports-json)

(struct support-entry (transport platform evidence notes) #:transparent)

(define evidence-levels
  '("ci-simulated" "implemented-unverified" "hardware-in-loop verified" "planned"))

(define entries
  (list
   (support-entry
    "socketcan" "Linux" "implemented-unverified"
    "Classic CAN 8-byte frames. Wire codec unit-tested on every platform; \
FD framing shares the code path. No physical adapter/ECU reproduction yet.")
   (support-entry
    "socketcan-fd" "Linux" "ci-simulated"
    "CAN FD data lengths up to 64, canfd_frame wire format, \
CAN_RAW_FD_FRAMES. The complete flash workflow runs over the simulated \
bus with FD framing in CI (examples/plan.sim-fd.json). Hardware \
reproduction pending.")
   (support-entry
    "pcan" "Windows" "implemented-unverified"
    "Classic CAN via the public PCAN-Basic DLL. No CI coverage (adapter \
required); no hardware reproduction report yet.")
   (support-entry
    "pcan-fd" "Windows" "planned"
    "CAN FD over PCAN waits on hardware qualification per the issue #4 \
gate — driver code is not shipped unverified.")
   (support-entry
    "doip" "cross-platform" "hardware-in-loop verified"
    "ISO 13400 DoIP over TCP. Reproduced end-to-end on a real ECU \
(2026-11, engine f14d1af): full cycle diagnostic-session / security \
access / precheck routine / sliced erase (110+ in-progress rounds) / \
538-block download / verify routine / activate routine / EcuReset / \
post-reset identity gate, twice consecutively. Plain-Ethernet adapter, \
Windows host, vendor-confidential reference ECU (a sectioned-download \
design); reproduction report on issue #4. Findings hardened into the \
engine: guarded RequestDownload block-length adoption, 1..255 sequence \
wrap, section-bounded chunking (chunkSplitOffsets), response-level \
FLASHPILOT_WIRE_TRACE bench evidence.")
   (support-entry
    "lin-simulated" "cross-platform" "ci-simulated"
    "UDS over LIN with ISO 17987-3 style diagnostic framing (0x3C/0x3D, \
NAD + PCI, 6-byte windows, master-paced). The full flash workflow runs \
over the simulated segment in CI (--transport lin). Hardware LIN \
adapters (PLIN/Kvaser and similar) are future work.")
   (support-entry
    "lin-hardware" "adapter-dependent" "planned"
    "Hardware LIN adapters wait on the same versioned adapter + \
reference-ECU reproduction gate as PCAN FD.")))

(define (support-entries) entries)

;; Deterministic JSON for the CLI contract.
(define (transports-json)
  (for/list ([e (in-list entries)])
    (hasheq 'transport (support-entry-transport e)
            'platform (support-entry-platform e)
            'evidence (support-entry-evidence e)
            'notes (string-trim (support-entry-notes e)))))
