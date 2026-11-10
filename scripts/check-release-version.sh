#!/usr/bin/env bash
# Release version gate: the three version sources must agree and the
# CHANGELOG must carry the matching dated section — the same checks the
# release workflow enforces, runnable on the machine before tagging.
#
#   scripts/check-release-version.sh            # the checked-in alignment
#   scripts/check-release-version.sh v0.2.0     # a specific tag
#
# VERSION is the single source of truth; a tag argument only asserts that
# the tag points at it. Aligned with taskly's check-release-version.sh
# (family discipline: the version sources are three and they never drift).

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

fail() { echo "FAIL: $1" >&2; exit 1; }

tag="${1:-}"
version=""
if [[ -n "$tag" ]]; then
  version="${tag#v}"
  [[ "$tag" == "v$version" ]] || { echo "tag must look like v<version> (got '$tag')" >&2; exit 1; }
fi

[[ -f VERSION ]] || fail "VERSION file is missing"
version_file="$(tr -d '[:space:]' < VERSION)"
[[ -n "$version_file" ]] || fail "VERSION file is empty"
[[ "$version_file" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail "VERSION '$version_file' is not x.y.z"
if [[ -n "$tag" ]]; then
  [[ "$version" == "$version_file" ]] || \
    fail "tag '$tag' does not match VERSION $version_file"
fi
version="$version_file"

grep -q "^## \[${version}\]" CHANGELOG.md \
  || fail "CHANGELOG.md has no '## [${version}]' section"
grep -q "(version . \"${version}\")" rivet.rktd \
  || fail "rivet.rktd version is not ${version}"
grep -q "(define version \"${version}\")" racket/info.rkt \
  || fail "racket/info.rkt version is not ${version}"
grep -q "'version \"${version}\"" app/backend.rkt \
  || fail "app/backend.rkt bench-status version is not ${version}"
grep -q "(define cli-version \"${version}\")" app/cli.rkt \
  || fail "app/cli.rkt cli-version is not ${version}"

echo "OK: VERSION, CHANGELOG, rivet.rktd, racket/info.rkt, app/backend.rkt and app/cli.rkt all agree on ${version}"
