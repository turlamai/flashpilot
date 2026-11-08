#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
output="$repo/.rivet/acceptance/macos"
app="$repo/dist/flashpilot.app/Contents/MacOS/flashpilot"
driver="$output/macos-ax"
home="$output/home-$$"
mkdir -p "$output" "$home"
[[ -x "$app" ]]

swiftc "$repo/scripts/e2e/macos-ax.swift" -o "$driver" \
  -framework AppKit -framework ApplicationServices

# Standalone simulated DoIP entity (resets away its TCP link); the app's
# Target port defaults to it via FLASHPILOT_SIM_DOIP_PORT.
racket "$repo/app/cli.rkt" sim-server --refuse-seconds 2 >"$output/sim-server.log" 2>&1 &
sim_pid=$!
sim_port=""
for _ in $(seq 1 1200); do
  if [[ -s "$output/sim-server.log" ]]; then
    sim_port=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$output/sim-server.log" | head -1)
    [[ -n "$sim_port" ]] && break
  fi
  sleep 0.1
done
[[ -n "$sim_port" ]] || { echo "simulated DoIP server did not report a port" >&2; echo "--- sim-server.log ---" >&2; cat "$output/sim-server.log" >&2 2>/dev/null || true; exit 1; }

FLASHPILOT_SIM_DOIP_PORT="$sim_port" HOME="$home" "$app" >"$output/application.log" 2>&1 &
app_pid=$!

stop_bounded() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 200); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  return 1
}
cleanup() {
  local status=$?
  trap - EXIT
  [[ -n "${sim_pid:-}" ]] && kill -0 "$sim_pid" 2>/dev/null && kill -TERM "$sim_pid" 2>/dev/null || true
  if kill -0 "$app_pid" 2>/dev/null; then
    stop_bounded "$app_pid" || true
    wait "$app_pid" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT

"$driver" --pid "$app_pid" --output "$output"
for _ in $(seq 1 200); do
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$app_pid" 2>/dev/null; then
  echo "FlashPilot did not exit after the native termination request" >&2
  exit 1
fi
wait "$app_pid"
trap - EXIT
