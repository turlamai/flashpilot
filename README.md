# FlashPilot

**Agent-native ECU flashing — UDS over CAN, DoIP and LIN, driven by declarative flash plans and built for coding agents.**
A focused flashing workflow: a free AGPL engine (no per-flash or per-seat fees, CI and agent automation included) with an official validated distribution planned as the paid tier — one resident-free CLI, deterministic JSON, exit codes that never lie, and failure evidence that lets an agent self-diagnose.

[![CI](https://github.com/turlamai/flashpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/flashpilot/actions/workflows/ci.yml) ![platform](https://img.shields.io/badge/platform-Windows_%7C_Linux_%7C_macOS-lightgrey) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

**English** · [中文](README.zh-CN.md) · [User guide](https://flashpilot.jrtx.site/guide.html)

## Start here

The AGPL engine, CLI and MCP remain free, including CI use under the existing licence. Validated official engineering assets are planned; no paid edition is on sale. Desktop source/preview paths target macOS, Windows and Linux. The published archive set does not imply every adapter, ECU or bus has been qualified.

[Installation, first use, privacy, backup and recovery](docs/USER-GUIDE.md) · [简体中文](docs/USER-GUIDE.zh-CN.md)

## Why FlashPilot?

Automotive flashing today means vFlash: expensive per-seat licenses, a Windows GUI, and automation only through a COM API that agents can't drive. The flashing knowledge itself — seed-key algorithms, memory layouts, sequences — used to be a moat of accumulated authoring. In the AI era that authoring cost collapses: an agent can draft a flash plan from an OEM spec. What remains valuable is the **closed loop**: generate a plan → verify its fingerprint → flash with power/sequence guards → collect evidence on failure → regenerate.

FlashPilot is built around that loop.

- **Declarative flash plans** — one JSON document per ECU: segments (inline, BIN, Intel HEX, S-record), session, security access with pluggable key providers, erase/download/verify routines, timings, recovery strategy, power guard, ECU identification gate, expected fingerprint.
- **ODX import + plan lint** — import the flash subset of ASAM ODX (`.odx`/`.pdx`: MEMORY-SEGMENT ranges, inline DATA, DATAFILE references) into a plan with honest reporting of everything not converted; lint plans for overlapping segments, empty ranges and gaps before any driver call.
- **Real transports** — SocketCAN (Linux), PEAK PCAN (Windows), DoIP (Ethernet). ISO-TP (ISO 15765-2) underneath on classic CAN **and CAN FD** (plan `dataLength` up to 64, SocketCAN FD framing, simulated FD bus). **UDS over LIN ships simulated** (ISO 17987-3 style diagnostic framing, `--transport lin`): the protocol layer is complete and CI-tested; hardware LIN adapters are future work.
- **Agent-first CLI and MCP server** — deterministic JSON output, exit codes that never lie, and failure evidence (bounded, fingerprinted, audited) so an agent can diagnose and retry without a human opening a vendor tool. The same engine also speaks MCP over stdio: `validate`, `flash`, `request`, `udid` and ODX import as agent tools.
- **Safety by default** — plans validate expected fingerprints before any driver call; in-programming power guards abort on out-of-band current; destructive plans say so.

Not a CANoe clone: no vehicle-network simulation, no CAPL, no analysis-window collection. One loop done honestly.

## Status

**v0.1.x — core engine**: UDS (ISO 14229) with P2/P2* timing and NRC handling, UDS flash workflow (session → security access → erase → download → verify → reset) with per-step audit, declarative plans with recovery strategies (retry / reset-and-retry), image fingerprint gate, in-programming power guard, DTC read/clear, Intel HEX + S-record + BIN image models, pluggable security providers (`command:<id>` external algorithms), ISO-TP over simulated CAN and DoIP, and a built-in simulated ECU so the entire loop runs hardware-free in CI.

The next gates: DoIP Ethernet hardening against real ECUs, hardware LIN adapters, and a plan library. CAN FD shipped: set `"dataLength": 64` in a plan (see `examples/plan.sim-fd.json`) and the whole loop — simulated ECU included — runs FD framing. LIN shipped simulated: `racket app/cli.rkt flash examples/plan.sim.json --transport lin`.

**Released**: v0.1.0 ships the agent-first CLI (`flash` / `verify` / `dtc` / `request` / `udid`) for Windows x64, Linux x64/arm64 and macOS arm64/x64 — versioned ZIP per platform plus one verified SHA256SUMS on the [Releases](https://github.com/turlamai/flashpilot/releases/latest) page. Bilingual user guide: <https://flashpilot.jrtx.site/guide.html>.

## Quick start

Download a released CLI (no Racket needed), unpack, and flash the built-in simulated ECU — hardware-free:

```bash
unzip flashpilot-0.1.0-macos-arm64.zip -d flashpilot
./flashpilot/bin/flashpilot flash examples/plan.sim.json
```

Or run from source:

```bash
git clone https://github.com/turlamai/flashpilot.git
cd flashpilot
raco pkg install --auto --name flashpilot --link racket
racket app/cli.rkt flash examples/plan.sim.json
racket app/cli.rkt validate examples/plan.sim.json
racket scripts/mcp-smoke.rkt   # agent surface: MCP over stdio
```

Import an OEM ODX/PDX into an editable plan (the supported subset is
reported honestly — anything not converted lands in `issues`):

```bash
racket app/cli.rkt odx-import oem-flash.pdx > plan.json
racket app/cli.rkt validate plan.json
```

Coding agents can drive the whole loop over MCP
(`racket app/mcp.rkt`): `flashpilot_validate`, `flashpilot_flash`,
`flashpilot_request`, `flashpilot_udid`, `flashpilot_odx_import`.

The default transport is a built-in simulated ECU — the whole flash loop runs hardware-free (real output):

```json
{"bytes":30,"error":null,"fingerprint":"144252e810505c9f","ok":true,"steps":["diagnostic-session","security-access","erase","download","verify","ecu-reset"]}
```

Against a real ECU over DoIP:

```bash
racket app/cli.rkt flash plan.doip.json --transport doip --host 192.168.0.1
```

## CLI

| command | purpose |
|---|---|
| `flash <plan.json>` | run a declarative flash plan (fingerprint gate, power guard, recovery) |
| `verify <plan.json>` | plan + fingerprint checks only — no ECU contact |
| `dtc read \| clear` | diagnostic trouble codes (UDS 0x19 / 0x14) |
| `request <hex>` | one raw UDS request |
| `udid <did>` | read a DID (22 XX XX) |

Exit codes: `0` ok · `1` flash/assert failed · `2` usage · `3` not found · `4` transport.

Every command prints one JSON object — camelCase fields, stable names, bounded error text — so an agent parses output without ever screen-scraping.

`flash <plan> --report <path>` additionally writes the run as a `flashpilot.report/v1` evidence artifact: UTC start, transport, the audited steps with timings, the identity and fingerprint gate records, the outcome. Failed runs write the same report — the failure is the evidence that matters most.

## Flash plans

```json
{
  "segments": [{ "address": "0x08000000", "file": "app.hex" }],
  "securityLevel": 1,
  "keyDeriver": "xor0x5a",
  "onFail": "resetAndRetry",
  "powerGuard": { "minMa": 5, "maxMa": 1500, "pollMs": 200 },
  "expectedIdentity": [{ "did": "0xFD00", "value": "ready" }],
  "expectedFingerprint": "e3400821709d3e50"
}
```

- `onFail` — `retry` or `resetAndRetry` (best-effort ECU reset, then one retry).
- `powerGuard` — polls the bench supply while programming; out-of-band current powers off and aborts.
- `expectedIdentity` — ECU identification gate: DIDs are read and compared byte-exact as the first flash step; a wrong target is never touched.
- `erasePoll` — polled erase for slice-erase ECUs: repeat the erase routine until a status byte reports done (`statusByte`/`maxRounds`/`roundTimeoutMs`), abort honestly on exhaustion.
- `expectedFingerprint` — pins the image; mismatch is rejected before any driver call.

Segments take inline hex (`data`) or raw `.bin` files (`file`), resolved relative to the plan's directory. Intel HEX / S-record parsing ships in the image model; plan-level wiring for `.hex`/`.s19` files is coming. Seed-key algorithms beyond the built-ins plug in as external commands: `"keyDeriver": "command:./my-oem-algo"`.

Full field reference and copy-pasteable examples: the [user guide](https://flashpilot.jrtx.site/guide.html).

## Testing

A built-in simulated ECU answers the real ISO-TP/UDS stack hardware-free:

```bash
raco test racket/flashpilot
```

## License

AGPL-3.0.
