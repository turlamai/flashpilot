# Signed CLI update roadmap

FlashPilot v0.1.0 is distributed as standalone ZIP archives for Windows,
macOS and Linux. The GUI debug cockpit is not a published desktop
application. **The current release is manual-update only**: it publishes
SHA256SUMS but does not publish an Ed25519-signed release feed, and no
installed CLI has an embedded official update trust root.

## Phase 1: offline trust policy

`app/update-policy.rkt` is a non-networked update *preview* using Rivet's
common signed manifest format. It does not touch a device, replace the CLI,
read local flashing plans, or alter any configured transport. It requires:

- An explicit user or agent command before checking for updates.
- The **installed CLI's embedded** Ed25519 public key and pinned key ID.
  These may not be taken from the downloaded manifest, environment or a
  caller-controlled URL.
- A valid stable-channel, newer SemVer release for application
  `site.jrtx.flashpilot` and exactly the current OS/architecture.
- A `cli`-component portable ZIP entry with an immutable canonical tag URL:
  `https://github.com/turlamai/flashpilot/releases/download/v<version>/flashpilot-<version>-<os>-<arch>.zip`.
  Moving `latest` aliases are for human convenience, **not signed payload
  identity**.
- A 1 MiB maximum manifest and 512 MiB signed ZIP size limit. A later
  downloader must also enforce the exact authenticated size and SHA-256.

Negative tests include forged signatures, wrong key ID, foreign-owner URLs,
query/fragment substitution, app-component substitution, unsupported platform,
downgrades and oversized metadata or payloads. CI runs these tests on all
three operating systems without accessing any production release credentials.

## Remaining release and CLI integration work

1. Provision a dedicated Ed25519 update signing key in the protected
   release system and **embed only the authenticated public trust root**
   and key ID in built CLI distributions. Do not add private signing
   material to this repository.
2. Extend the release job to sign the *exact five* versioned ZIP archives,
   publish the signed manifest and fail closed on a missing/mismatched
   signing key. Verify manifest/file parity before uploading the Release.
3. Add an explicit `flashpilot update check` command (with stable JSON,
   documented exit codes), and `flashpilot update download` using Rivet's
   timeout-bounded, signed-size, SHA-256-verified downloader. No implicit
   update check on ordinary flash/validate/verify commands.
4. Keep installation a deliberate, separate operator action. If installed
   by a package manager, delegate to that manager. Never overwrite an
   in-use CLI executable or hide a failed replacement.
5. Exercise actual extracted-version N-to-N+1 upgrades on Windows, macOS
   and Linux, including user configuration preservation, cancellation and
   rollback, before advertising complete update support.

A signed manifest is necessary, but not sufficient to declare an actual
upgrade path working. Existing v0.1.0 builds will need a documented one-time
manual upgrade because they cannot trust a future feed retroactively.

Tracking issue: #17.
