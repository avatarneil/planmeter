#!/usr/bin/env bash
# Smoke run for planmeterd inside the Linux build container (see run.sh smoke):
# start the daemon with remote access on loopback, exercise every control
# endpoint over the Unix socket with curl, pair a real RemoteClient and call
# every RPC (LiveDaemonTests), then shut down with SIGTERM.
#
# By default HOME is a scratch directory with one synthetic Claude transcript.
# Set PLANMETER_SMOKE_HOME to scan real (read-only mounted) provider homes.
# Pairing secrets are redacted from the output.
set -euo pipefail

src=/work/src
build=/work/build
bin="$(swift build --package-path "$src" --scratch-path "$build" --show-bin-path)/planmeterd"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ -n "${PLANMETER_SMOKE_HOME:-}" ]; then
  export HOME="$PLANMETER_SMOKE_HOME"
  state=(--config-dir "$scratch/config" --state-dir "$scratch/state")
else
  export HOME="$scratch/home"
  mkdir -p "$HOME/.claude/projects/demo"
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$now\",\"requestId\":\"req_1\",\"sessionId\":\"s1\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-sonnet-4-5\",\"usage\":{\"input_tokens\":1200,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":8000,\"output_tokens\":400}}}" \
    > "$HOME/.claude/projects/demo/s1.jsonl"
  state=()
fi
export XDG_RUNTIME_DIR="$scratch/run"
mkdir -m 700 -p "$XDG_RUNTIME_DIR"
sock="$XDG_RUNTIME_DIR/planmeter/control.sock"
redact() { sed -E 's/([?&#]t=)[A-Za-z0-9_-]+/\1<redacted>/g; s/#k=[^"]*/#<redacted>/g; s/"webCode":"[0-9]+"/"webCode":"<redacted>"/g'; }

"$bin" --version
"$bin" --remote --loopback --offline --pairing-link "${state[@]}" > "$scratch/out.log" 2> "$scratch/err.log" &
pid=$!
for _ in $(seq 1 100); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { cat "$scratch/err.log"; echo "control socket did not appear" >&2; exit 1; }

failures=0
call() {
  local method="$1" path="$2" body="${3:-}" expect="${4:-200}" status
  status="$(curl -s -o "$scratch/body" -w '%{http_code}' --unix-socket "$sock" -X "$method" "http://localhost$path" ${body:+-d "$body"})"
  printf '%-6s %-60s %s %s\n' "$method" "$path" "$status" "$(redact < "$scratch/body" | cut -c1-110)"
  if [ "$status" != "$expect" ]; then echo "  expected $expect" >&2; failures=$((failures + 1)); fi
}

echo "--- control socket"
stat -c '%A %n' "$XDG_RUNTIME_DIR/planmeter" "$sock"
echo "--- control API"
call GET /v1/status
call POST /v1/refresh '{"forceAccountUsage":true}'
call POST /v1/rpc '{"method":"summary","days":1}'
call POST /v1/rpc '{"method":"timeline","minutes":60,"resolution":"5m"}'
call GET /v1/settings
call PUT "/v1/settings/groups/claude%3Ahome%3A$(python3 -c 'import os,urllib.parse; print(urllib.parse.quote(os.environ["HOME"] + "/.claude/projects", safe=""))')" '{"group":"work"}'
call PUT /v1/settings/spend '{"groups":["personal","work"],"thresholds":{"today":{"limit":10,"warningPercent":80}}}'
call PUT /v1/settings/spend '{"groups":[]}' 400
call GET /v1/remote
call PUT /v1/remote '{"httpsEnabled":false}'
call POST /v1/remote/invite
call DELETE /v1/remote/invite
call DELETE /v1/remote/devices/unknown '' 404
call GET /v1/unknown '' 404
call PATCH /v1/status '' 405

echo "--- remote API over loopback"
curl -s -w ' [%{http_code}]\n' http://127.0.0.1:7787/v1/info
curl -s -o /dev/null -w 'GET / -> %{http_code} %{content_type}\n' http://127.0.0.1:7787/
link="$(curl -s --unix-socket "$sock" -X POST http://localhost/v1/remote/invite | python3 -c 'import json,sys; print(json.load(sys.stdin)["invite"]["localUrl"])')"
if PLANMETER_LIVE_PAIRING_LINK="$link" swift test --package-path "$src" --scratch-path "$build" --skip-build --filter LiveDaemonTests > "$scratch/live.log" 2>&1; then
  grep -E '^live:' "$scratch/live.log" || true
else
  cat "$scratch/live.log"; failures=$((failures + 1))
fi
curl -s --unix-socket "$sock" http://localhost/v1/remote | python3 -c 'import json,sys; print("paired devices:", [(d["name"], d["requestCount"]) for d in json.load(sys.stdin)["devices"]])'

echo "--- files"
if [ -n "${PLANMETER_SMOKE_HOME:-}" ]; then dirs=("$scratch/config" "$scratch/state"); else dirs=("$HOME/.config/planmeter" "$HOME/.local/state/planmeter"); fi
find "${dirs[@]}" -maxdepth 2 \( -name '*.json' -o -type d \) -exec stat -c '%A %n' {} \; 2>/dev/null || true

echo "--- shutdown"
kill -TERM "$pid"
wait "$pid" && echo "exit 0" || { echo "exit $?"; failures=$((failures + 1)); }
if [ -e "$sock" ]; then echo "socket left behind"; failures=$((failures + 1)); else echo "socket removed"; fi
echo "--- stdout"; redact < "$scratch/out.log"
echo "--- stderr"; cat "$scratch/err.log"
[ "$failures" -eq 0 ] && echo "smoke: ok" || { echo "smoke: $failures failure(s)" >&2; exit 1; }
