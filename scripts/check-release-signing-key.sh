#!/usr/bin/env bash
set -euo pipefail
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
test -n "${UPDATE_ED25519_PRIVATE_KEY_B64:-}" && test -n "${UPDATE_ED25519_PUBLIC_KEY_B64:-}" || { echo "Release key and independently configured public trust root required" >&2; exit 1; }
printf "%s" "$UPDATE_ED25519_PRIVATE_KEY_B64" | base64 -d > "$tmp/private.der"
printf "%s" "$UPDATE_ED25519_PUBLIC_KEY_B64" | base64 -d > "$tmp/trusted.der"
openssl pkey -inform DER -in "$tmp/private.der" -pubout -outform DER -out "$tmp/derived.der" 2>/dev/null
[[ "$(od -An -tx1 -N12 "$tmp/trusted.der" | tr -d ' \n')" == 302a300506032b6570032100 && "$(wc -c < "$tmp/trusted.der" | tr -d '[:space:]')" == 44 ]] || { echo "Trust root must be Ed25519 SPKI DER" >&2; exit 1; }
cmp -s "$tmp/derived.der" "$tmp/trusted.der" || { echo "Release key mismatch" >&2; exit 1; }
echo "Release key matches configured public trust root"
