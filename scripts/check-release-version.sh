#!/usr/bin/env bash
# Release version gate: the three version sources must agree and the
# CHANGELOG must carry the matching dated section — the same checks the
# release workflow enforces, runnable on the machine before tagging.
#
#   scripts/check-release-version.sh            # VERSION = next unreleased
#   scripts/check-release-version.sh v0.2.0     # a specific tag
#
# Aligned with taskly's check-release-version.sh (family discipline: the
# version sources are three and they never drift).

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

tag="${1:-}"
if [[ -n "$tag" ]]; then
  version="${tag#v}"
  [[ "$tag" == "v$version" ]] || { echo "tag must look like v<version> (got '$tag')" >&2; exit 1; }
else
  version="$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' CHANGELOG.md | head -1)"
  [[ -n "$version" ]] || { echo "no dated version section found in CHANGELOG.md" >&2; exit 1; }
  echo "checking CHANGELOG head version: $version"
fi

fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q "^## \[${version}\]" CHANGELOG.md \
  || fail "CHANGELOG.md has no '## [${version}]' section"
grep -q "(version . \"${version}\")" rivet.rktd \
  || fail "rivet.rktd version is not ${version}"
grep -q "(define version \"${version}\")" racket/info.rkt \
  || fail "racket/info.rkt version is not ${version}"
grep -q "'version \"${version}\"" app/backend.rkt \
  || fail "app/backend.rkt bench-status version is not ${version}"

echo "OK: CHANGELOG, rivet.rktd, racket/info.rkt and app/backend.rkt all agree on ${version}"
