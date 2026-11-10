# Third-party notices

FlashPilot builds on the components below. Each entry names where the
component enters the shipped artifacts and the license it is distributed
under; consult the upstream license files for full terms. The Rivet
toolchain is a first-party TurLamAI project (MIT) consumed as a pinned
package — not third-party code — so it is not listed here.

## Racket CS runtime

The release ZIP archives embed the compiled Racket CS runtime and the
standard-library modules the CLI uses
([racket/racket](https://github.com/racket/racket), 9.x, via
`raco exe` + `raco distribute`). Racket is distributed under the MIT
license and the Apache License 2.0, at your option; the Racket CS
runtime system additionally embeds Chez Scheme, distributed under the
Apache License 2.0 (per Racket's `LICENSE.txt`).

FlashPilot's own payload — the `flashpilot` collection and the `app/`
entries — carries AGPL-3.0 (see `LICENSE`). No other third-party code
is vendored into the release archives.

## Racket `crypto` package (signing tooling and tests only)

The offline update-manifest signer (`scripts/sign-cli-update-manifest.rkt`)
and the update-trust tests (`tests/update-policy-test.rkt`,
`tests/sign-cli-update-manifest-test.rkt`) use the Racket
[crypto](https://github.com/rmculpepper/crypto) package, distributed
under the MIT license and the Apache License 2.0, at your option, with
Ed25519 provided through OpenSSL's `libcrypto` (Apache License 2.0 for
OpenSSL 3.x releases; older 1.x releases carry the OpenSSL/SSLeay
license). These paths are operator signing tooling and CI test
infrastructure — the `crypto` library is **not** linked into the
shipped CLI archives, and the current manual-update release performs no
signature verification of its own (see
[SECURITY.md](SECURITY.md) and
[docs/CLI-UPDATE-CONTRACT.md](docs/CLI-UPDATE-CONTRACT.md)).

## Distribution rule

Official FlashPilot releases are portable ZIP archives per OS/arch:
each contains the FlashPilot AGPL-3.0 payload, the embedded Racket CS
runtime and the bundled example plans. Nothing else ships: no installer
wizard, no background service, no third-party binaries. If a future
release starts bundling any additional component, this notice must
gain the corresponding entry before that release ships.
