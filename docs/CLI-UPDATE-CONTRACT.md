# Signed CLI update roadmap

FlashPilot is distributed as standalone ZIP archives for Windows,
macOS and Linux. The GUI debug cockpit is not a published desktop
application. **Updates remain manual for installed CLIs**: every release
now publishes an Ed25519-signed feed (`update-manifest.json` as a release
asset), but no installed CLI ships with an embedded official update trust
root yet, so nothing consumes the feed automatically — installation stays
a deliberate operator action per this contract.

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

## Offline five-platform signing preparation

`scripts/sign-cli-update-manifest.rkt` prepares the exact signed vNext
manifest from these five versioned ZIPs: Windows x64; Linux x64 and arm64;
macOS x64 and arm64. Its required inputs are the version, build number,
physical archive directory, protected Ed25519 private key file, separately
pinned **client-trusted** public key file, and key identifier.

```sh
racket scripts/sign-cli-update-manifest.rkt \
  --version 0.2.0 --build 2 --dir dist \
  --private-key /secure/update-private.der \
  --public-key /secure/client-trust-root.der \
  --key-id flashpilot-release-2026
```

The script requires all five files, signs their exact SHA-256 and sizes with
the official immutable version-tag URLs, then verifies the written Ed25519
wrapper using the client public key *before atomically publishing* the
manifest. A signer mismatch or missing archive leaves an existing
manifest untouched. CI uses synthetic keys and disposable archives to test
this behavior on every platform.

**The release workflow now publishes the signed feed**: the publish job
signs `update-manifest.json` with the `UPDATE_ED25519_PRIVATE_KEY_B64`
secret (base64 DER — the exact form `read-ed25519-private-key` consumes;
missing secret fails the release before anything is uploaded, so no
unsigned feed can ship) and attaches it as a release asset alongside the
archives. The round-trip verification inside the job uses the public half
derived from the same release key — a placeholder until the real client
trust root exists, which is why the feed is *published but not yet
client-trusted*.

## Remaining release and CLI integration work

1. Provision a dedicated Ed25519 update signing key in the protected
   release system (`UPDATE_ED25519_PRIVATE_KEY_B64` — the publish job
   already fail-closes on it) and **embed only the authenticated public
   trust root** and key ID (`flashpilot-release-2026`) in built CLI
   distributions. Do not add private signing material to this
   repository.
2. Publish the feed: **done** — the release job signs
   `update-manifest.json` as a release asset with fail-closed gate
   behavior and archive parity checks; once clients embed the trust root
   they can trust it with no feed-side change.
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
