# Changelog

All notable changes to FlashPilot are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [Unreleased]

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
