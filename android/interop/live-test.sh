#!/usr/bin/env bash
# Pairs the Kotlin JVM client with the Swift interop host and calls every RPC
# method (LiveSwiftServerTest). macOS only: the host uses this checkout's
# PlanMeterRemote and Network.framework; the Kotlin side runs in Docker and
# reaches the host's loopback through host.docker.internal (OrbStack and Docker
# Desktop both provide it).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scratch="${TMPDIR:-/tmp}/planmeter-interop-build"
port="${PLANMETER_INTEROP_PORT:-7799}"
invite_file="$(mktemp)"
log_file="$(mktemp)"

swift build --package-path "$here/swift" --scratch-path "$scratch" >&2
"$scratch/debug/planmeter-interop" serve --port "$port" --advertise-host host.docker.internal \
  --invite-file "$invite_file" --seconds 900 2> "$log_file" > /dev/null &
server=$!
trap 'kill -INT $server 2>/dev/null || true; wait $server 2>/dev/null || true; cat "$log_file"; rm -f "$invite_file" "$log_file"' EXIT

for _ in $(seq 50); do [[ -s "$invite_file" ]] && break; sleep 0.1; done
PLANMETER_INTEROP_PAIR_URL="$(cat "$invite_file")" \
  "$here/../scripts/docker-gradle.sh" :protocol:test --tests '*LiveSwiftServerTest*' --rerun
