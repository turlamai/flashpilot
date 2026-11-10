# Contributing to FlashPilot

Thank you for looking under the hood. FlashPilot is free software
(AGPL-3.0, see [LICENSE](LICENSE)): by submitting a pull request you
agree your contribution is licensed under AGPL-3.0.

## Ground rules

1. **The CLI contract is deterministic JSON with exit codes that never
   lie.** Every command prints exactly one JSON object on stdout (`0`
   ok, `1` flash/assert failed, `2` usage, `3` not found, `4`
   transport/internal). If you change a command's output or codes,
   change the usage text, the README table and the tests in the same
   commit — agents parse these bytes, not prose
   (`tests/cli-test.rkt` pins the identity contract).
2. **Safe by default is a gate, not a slogan.** Plan lint, the
   `expectedIdentity` ECU gate and the `expectedFingerprint` image gate
   run before any transport opens; pre-flight failures never touch the
   ECU or write a report. A change that lets a plan half-execute, that
   widens what runs at plan-load time, or that leaks provider
   (seed-key / power-meter) output into logs or reports is a security
   regression ([SECURITY.md](SECURITY.md)).
3. **Simulated is the CI truth; hardware is evidence.** The built-in
   simulated ECU keeps the whole loop hardware-free, and the support
   matrix's evidence levels (`ci-simulated` / `implemented-unverified` /
   `planned`) are honest labels generated from the transport modules —
   never promote a claim without the recorded real-hardware evidence
   (see the support matrix and issue #4 for the DoIP precedent).
4. **The update posture is written down.** The current release is
   manual-update only ([docs/CLI-UPDATE-CONTRACT.md](docs/CLI-UPDATE-CONTRACT.md)
   owns the roadmap: embedded trust root first, then the protected
   signer, then explicit `update` commands). No implicit update check
   on ordinary commands; the offline preview policy in
   `app/update-policy.rkt` must keep trusting only an installed CLI's
   embedded key and pinned key id.
5. **Rivet is pinned, hosts are per-platform.** Rivet is consumed at a
   fixed commit — never drift to tag/main; a pin bump updates CI,
   acceptance and [AGENTS.md](AGENTS.md) together and goes through
   three-platform packaging. Desktop hosts live in platform legs and
   must be built and driven by `raco rivet acceptance` — Racket/CLI
   tests do not substitute for GUI delivery proof.
6. **`rivet-acceptance.rktd` is the executable definition of done.** Do
   not delete requirements, weaken assertions, or reuse old evidence to
   turn a result green.
7. **Tests pin contracts.** If you change behavior a test covers,
   change the test in the same commit and say why. Negative tests are
   part of the contract (forged signatures, wrong key ids, hostile
   plans, oversized payloads).

## Before you push

```bash
bash scripts/check-release-version.sh          # VERSION == CHANGELOG == rivet.rktd == info.rkt == backend == CLI
raco test racket/flashpilot                    # engine contract tests
raco test tests/cli-test.rkt                   # CLI identity contract (--version, exit codes)
raco test tests/update-policy-test.rkt         # offline signed-update trust tests
raco test tests/sign-cli-update-manifest-test.rkt
racket app/cli.rkt verify examples/plan.sim.json
racket app/cli.rkt validate examples/plan.sim.json
racket app/cli.rkt flash examples/plan.sim.json
```

These mirror the CI `test` job (which additionally compiles the entry
points with `raco make`, exercises CAN FD and LIN simulated plans, and
smokes the MCP server). Desktop hosts compile in their own CI jobs —
if you touch `macos-host/`, `windows/` or `linux/`, say whether you
were able to build locally.

## Reporting issues

Include: OS + version, FlashPilot version (`flashpilot --version`),
install shape (release ZIP / source checkout), transport (sim / CAN /
DoIP / LIN), the exact plan JSON (or the smallest reproducing one),
and the full stdout JSON plus exit code. For flash failures, attach
the `flashpilot.report/v1` report written by `--report` — it exists
precisely so failures are diagnosable without the bench. Security
issues go through [SECURITY.md](SECURITY.md), not public issues.
