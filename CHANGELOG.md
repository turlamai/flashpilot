# Changelog

All notable changes to FlashPilot are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [Unreleased]

### Added

- **Live flash timeline** — the desktop hosts stream the audited workflow
  as it happens: the backend emits `plan-progress` events per engine
  step, and all three hosts render a live timeline while the flash runs
  instead of freezing until the final JSON.
- **Report-shaped flash results** — the desktop hosts receive the full
  `flashpilot.report/v1` shape for every flash (schema, UTC start,
  transport, fingerprint and gate records, audited steps): what the CLI
  `--report` writes to disk is what the GUI surfaces, so a report is one
  JSON dump away from traceability.
- **DoIP connection surface** — the desktop hosts gain a Target section
  (host, port, reconnect attempts; Flash over DoIP): the new
  `flash-plan-remote` RPC drives the same audited workflow over real
  TCP, with the reconnect policy and report shaping identical to the
  CLI. A new `flashpilot sim-server` command starts a standalone
  simulated DoIP entity that resets away its TCP link and refuses
  connections for a window — the packaged-GUI acceptance on all three
  platforms now flashes over DoIP against that resetting ECU, exercising
  the reconnect path end to end (issue #50).

## [0.2.0] - 2026-11-08

### Changed

- The simulated ECU identifies itself as `FlashPilot sim-ecu v1.0.4`; the
  retired bench brand no longer appears in the identity string, the bench
  status surface or the manual (issue #30).

### Fixed

- The Windows standalone CLI ZIP now executes `bin/flashpilot.exe` instead of
  the Racket-distribute default of a root-level executable (issue #10).
  Building directly into `stage/bin` preserves Racket's Windows DLL lookup;
  CI extracts the actual ZIP into a fresh directory and verifies CLI commands,
  simulated flash and failure exit code, without depending on the source tree.
  Existing v0.1.0 artifacts are unchanged.

### Added

- **ECU identification gate** — plans accept `expectedIdentity` DID checks
  (`did` + exact-byte `value`/`valueHex`). The engine reads and compares
  them as the first flash step, before DiagnosticSessionControl: a wrong
  target, unsupported DID or short payload aborts with bounded
  expected/got evidence before any session change, unlock or erase
  (issue #30). `verify` and the bench `verify-plan` surface the configured
  expectations; `examples/plan.sim.json` gates on the simulated ECU's
  `0xFD00` "ready" DID.
- **Flash reports** — `flashpilot flash <plan> --report <path>` writes the
  run as a `flashpilot.report/v1` JSON evidence artifact: UTC start,
  transport, audited steps with timings, identity/fingerprint gate records
  and the outcome. Failed attempts write the same report; stdout JSON is
  unchanged.
- **Polled erase** — plans accept `erasePoll` (`statusByte`/`maxRounds`/
  `roundTimeoutMs`): the engine repeats the erase routine with the same
  record until the status byte reports done — the pattern slice-erase
  ECUs require — and aborts with bounded evidence when maxRounds is
  exhausted. Unset plans keep the historical single-shot erase. The
  simulated ECU gains an opt-in `erase-rounds-to-done` mode so the loop
  and its exhaustion path are CI-proven (issue #34).
- **Generic routine steps** — plans accept `routineSteps` entries at
  `before-erase` / `after-verify` (optional `record`, `timeoutMs`): the
  declarative answer to vendor prechecks and activations. The engine
  requires a positive response and audits the raw bytes; vendor status
  semantics are never interpreted. The simulated ECU accepts an opt-in
  `extra-routines` set, staying strict (requestOutOfRange) otherwise
  (issue #36).
- **Post-reset confirmation gate** — plans accept `postResetGate`
  (`did` + exact-byte `value`/`valueHex` + `timeoutMs`/`intervalMs`):
  after EcuReset the engine polls the DID until it matches, so a stuck
  ECU cannot yield a green run; timeout aborts with the last value read
  as bounded evidence (issue #38). On transports where a reset drops the
  link the gate requires channel re-establishment — the simulated
  channel provides it today; general DoIP reconnection ships with the
  DoIP hardening slice.
- **onFail enforced** — the parsed-but-not-enforced debt is settled:
  `retry` replays the whole transaction once after a non-permanent
  failure and `resetAndRetry` adds a best-effort hard EcuReset before
  the replay; both leave the failed attempt's abort, a `recovery` step
  and the replayed sequence in the audit. Permanent failures (wrong
  ECU at the identity gate) never replay. `onFail` moved onto the
  engine-facing plan record; `powerGuard` remains the one documented
  parsed-not-enforced field (issue #40).
- **DoIP bounded reconnect** — `--reconnect N [--reconnect-delay-ms MS]`
  (DoIP transport): after an EcuReset drops the TCP link, the channel
  re-establishes it (fresh connect + routing activation) within bounded
  attempts, so the post-reset confirmation gate keeps polling across the
  ECU's reboot window. Connection-class errors only — UDS negative
  responses and NACKs are never retried by this layer; with reconnect
  disabled the historical stop-at-error behavior is unchanged. A
  simulated DoIP entity that closes its link on reset and refuses
  connections for a window proves the reconnect and exhaustion paths in
  CI (issue #42).
- **Native flash surface** — the desktop hosts (Windows WinUI, macOS
  SwiftUI, Linux GTK4) gain a Flash button: the backend's new
  `flash-plan` RPC runs the plan against the simulated bench ECU and
  returns the audited steps as JSON — every failure a bounded result,
  never a dead screen. All three e2e acceptance drivers press the
  button and assert the result through the platform accessibility API.
  The backend also gained a shared plan loader, so what a host verifies
  is exactly what a host flashes.
- **powerGuard enforced** — the last parsed-not-enforced field is
  settled. `powerGuard` gains a required `provider`: `{"kind": "sim",
  "ma": N}` (deterministic, CI/benches) or `{"kind": "command",
  "command": "./bench-power"}` (external vendor script prints live mA on
  stdout — vendor code stays outside the engine). The engine polls the
  meter through erase and every download block (rate-limited by
  `pollMs`) and aborts **permanently** on out-of-band current — a
  physical safety event is never blindly retried. A plan never measures
  with a fake: no provider, no enforcement (issue #44).

- **Support matrix as code** — `flashpilot transports --json` emits every
  transport/adapter subset with an explicit evidence level
  (`ci-simulated` / `implemented-unverified` / `planned`) from
  `flashpilot/diagnostics/support-matrix.rkt`; PCAN FD and hardware LIN
  are labeled planned, and a hardware-in-loop level awaits a versioned
  adapter + reference-ECU reproduction report (issue #4 gate).
- **Recovery semantics documented** — `docs/support-matrix.md` (bilingual)
  records the block-retry bound, the power-loss re-run path (fingerprint
  gate, restart from erase), session-loss behavior and the guarantee that
  erase/download are never blindly retried; `onFail`/`powerGuard` plan
  fields are documented as parsed-but-not-yet-enforced.
- README positioning aligned with PRICING: free AGPL engine, official
  validated distribution as the planned paid tier.

- **UDS over LIN (simulated)** — `--transport lin` plus
  `flashpilot/diagnostics/isotp/lin-{tp,endpoint}.rkt` and
  `channels/lin-uds-channel.rkt`: ISO 17987-3 style diagnostic framing
  (0x3C/0x3D, NAD + PCI, 6-byte windows, master-paced, no flow control).
  The full flash workflow runs against the simulated ECU over LIN in CI.
  Hardware LIN adapters (PLIN/Kvaser) are future work.
- Fixed a latent simulated-bus race: an empty inbox initialized as `'()`
  (truthy) could crash a transport pump that polled before the first
  frame arrived; inboxes now start as `#f`.

- **CAN FD support** — plans accept `"dataLength"` (8 classic default; snaps
  to the nearest legal FD length up to 64). ISO-TP codec, endpoints and the
  simulated ECU chunk frames at the configured data length; SocketCAN gains
  `canfd_frame` wire support and enables `CAN_RAW_FD_FRAMES` in FD mode.
  Classic CAN behavior is bit-identical; PCAN FD waits on hardware
  verification. `examples/plan.sim-fd.json` flashes the simulated ECU over
  FD in CI.

- **ODX import (subset)** — `odx-import` command plus
  `flashpilot/diagnostics/flash/odx`: `.odx`/`.odx-f`/`.pdx` into flash
  plans (MEMORY-SEGMENT ranges, inline base64 DATA, DATAFILE references).
  Everything outside the subset is reported in `issues`, never dropped.
  CDD/VFD remain out of scope by design.
- **Plan validation lint** — `validate` command plus
  `flashpilot/diagnostics/flash/validation`: segment overlap (error),
  empty segments (warning), gaps (warning), missing data/file (error);
  `flash` refuses plans with validation errors.
- **MCP server** — `app/mcp.rkt`: stdio JSON-RPC 2.0 exposing
  `flashpilot_validate`, `flashpilot_flash`, `flashpilot_request`,
  `flashpilot_udid` and `flashpilot_odx_import` to coding agents;
  `scripts/mcp-smoke.rkt` gates the surface in CI.

## [0.1.0] - 2026-10-14

First release. CLI-first, three platforms: the flashing core, a declarative
plan format and an agent-first CLI — no GUI in the release artifacts (the
native shells stay in-repo as a debug cockpit).

### Added

- **UDS (ISO 14229) core** — P2/P2* timing, NRC taxonomy, DTC read/clear
  (0x19 / 0x14), DID read (0x22), TesterPresent, ECU reset.
- **UDS flash workflow** — session → security access → erase → download →
  verify → reset, with a per-step audit on every run.
- **Declarative flash plans** — one JSON document per ECU: segments (inline
  hex or raw BIN files), session, security level, key deriver,
  recovery strategy (`retry` / `resetAndRetry`), in-programming power guard,
  and an `expectedFingerprint` gate validated before any driver call.
  Intel HEX / S-record parsing ships in the image model.
- **Security providers** — built-in seed-key derivers plus pluggable external
  algorithms via `command:<id>`; vendor code stays in vendor binaries.
- **Transports** — SocketCAN (Linux), PEAK PCAN (Windows), DoIP (Ethernet);
  ISO-TP (ISO 15765-2) underneath. UDS over LIN is planned, not in this release.
- **Built-in simulated ECU** — a real ISO-TP/UDS stack answering behind a
  simulated CAN bus, so the entire flash loop runs hardware-free, including CI.
- **Agent-first CLI** — `flash` / `verify` / `dtc` / `request` / `udid`;
  deterministic single-line JSON output, stable exit codes (0 ok · 1
  flash/assert failed · 2 usage · 3 not found · 4 transport), bounded failure
  evidence so an agent can diagnose and retry without a vendor tool.
- **User guide** — bilingual (Chinese/English) manual at
  <https://flashpilot.jrtx.site/guide.html>.
- **Release engineering** — tagged builds produce per-platform CLI archives
  (zip + SHA-256) and a combined SHA256SUMS on GitHub Releases.

[0.2.0]: https://github.com/turlamai/flashpilot/compare/v0.1.0...v0.2.0
