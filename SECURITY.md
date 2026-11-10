# Security Policy

FlashPilot is an agent-native ECU flashing tool: it runs declarative
flash plans over UDS (CAN / DoIP / LIN) against a vehicle interface
plane, and it is safe by default — plans validate and fingerprint-gate
before any transport is opened, and the default transport is the
built-in simulated ECU. Reports are taken seriously and handled quickly.

## Reporting a vulnerability

Email **security@jrtx.site** (or open a GitHub security advisory on this
repository). Include reproduction steps, affected versions, and your
assessment of impact. You will get an acknowledgment within 72 hours.

Please do not open public issues for security problems.

## Scope

In scope:

- Flash plan parsing and validation: loading plan JSON, resolving
  segment image files relative to the plan, the ODX/PDX import subset,
  and the gates that run before device contact — plan lint, the
  `expectedIdentity` ECU gate and the `expectedFingerprint` image gate
  (`flashpilot/diagnostics/flash/plans.rkt`, `flash/validation.rkt`,
  `flash/odx.rkt`). A malformed or hostile plan must fail with a
  bounded JSON error and exit code `2` before any transport opens —
  never half-execute.
- The vehicle interface plane: the UDS protocol layer, ISO-TP framing
  and the CAN / DoIP / LIN transports (`diagnostics/uds/`,
  `diagnostics/isotp/`, `diagnostics/doip/`, `diagnostics/channels/`),
  including the bounded DoIP reconnect behavior across ECU reboot
  windows. The engine must never invent traffic the plan does not
  declare, and recovery (`onFail`) execution stays inside the plan's
  declared steps.
- Credential plumbing: pluggable seed-key derivation providers and
  power-meter providers run as external commands with plan-supplied
  arguments (`diagnostics/security-provider.rkt`,
  `flash/plans.rkt` power-guard structs). Provider output must reach
  only the diagnostic layer that requested it — never logs, reports or
  error text.
- Flash evidence: the `flashpilot.report/v1` report written by
  `--report` (`flash/report.rkt`) — evidence for agents, not a channel
  for secrets.
- Update trust posture: the current release is **manual-update only**
  (contract: [docs/CLI-UPDATE-CONTRACT.md](docs/CLI-UPDATE-CONTRACT.md) —
  SHA256SUMS, no signed feed, no embedded trust root). The offline
  update-preview policy (`app/update-policy.rkt`) and the offline
  five-archive signer (`scripts/sign-cli-update-manifest.rkt`) must
  keep their fail-closed properties: an installed CLI trusts only its
  **embedded** public key and pinned key id, never a key advertised by
  a feed, environment or caller-controlled URL.
- The MCP surface (`app/mcp.rkt`) and the CLI identity contract
  (`--version`, deterministic JSON, exit codes that never lie).

Out of scope: the ECU/vehicle itself and its firmware, attacks against
vehicles or ECUs in operation through legitimate diagnostic protocols,
defects in OS networking or in the Racket runtime — those belong to
their owners. FlashPilot is an engineering bench tool; using it against
equipment you are not authorized to flash is not a FlashPilot bug.

## Design notes reviewers should know

- **Safe by default, verified before contact.** Plan validation, the
  identity gate and the fingerprint gate all run before a transport is
  opened; pre-flight failures print their JSON and never reach the ECU
  or write a report. With no `--transport` flag every command runs
  against the built-in simulated ECU — hardware-free by default.
- **Exit codes never lie.** `0` ok, `1` flash/assert failed, `2` usage,
  `3` not found, `4` transport/internal — and every command prints
  exactly one JSON object on stdout. An agent diagnoses from the code
  plus the bounded error text; there is nothing to screen-scrape.
- **Providers are the only external code.** Seed-key derivations and
  power-meter meters are external commands named in the plan; the
  engine passes them bounded arguments and uses their output only for
  the requested UDS step. A provider failure is a failed step, not a
  bypass.
- **Updates stay manual today, on purpose.** The current release ships
  SHA256SUMS and no signed feed; adding feed signing before clients
  embed an official public trust anchor would create a feed no
  installed client can trust (docs/CLI-UPDATE-CONTRACT.md "Remaining
  work"). The offline preview policy already enforces: explicit
  consent, embedded key + pinned key id, stable channel, newer SemVer,
  exact OS/arch, immutable canonical tag URLs, 1 MiB manifest and
  512 MiB payload caps — with attacker-negative tests (forged
  signatures, wrong key id, URL substitution, downgrades, oversize)
  run in CI on every OS. Never represent the manual model as a
  signed-update path.
- **No telemetry, no resident process.** The CLI runs, reports,
  exits. Plans and reports live where the caller points them.

## Supported versions

Security fixes land on `main` first and ship with the next tagged release.
During the 0.x preview there is no LTS branch.
