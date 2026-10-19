#!/bin/sh
# Renders the README screenshots against the mock daemon under Xvfb.
# Run inside the dev image:  SHOTS=/tmp/planmeter-shots docker/dev.sh docker/screenshots.sh
set -eu
out=${1:-/shots}
mkdir -p "$out"
cargo build --quiet --bins
bin=${CARGO_TARGET_DIR:-target}/debug

export XDG_RUNTIME_DIR=/tmp/planmeter-runtime
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
# Keep saved window state and alert history out of the picture.
XDG_STATE_HOME=$(mktemp -d)
export XDG_STATE_HOME
export NO_AT_BRIDGE=1

"$bin/mock-planmeterd" &
mock=$!
trap 'kill $mock 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$XDG_RUNTIME_DIR/planmeter/control.sock" ] && break
  sleep 0.2
done

shot() {
  name=$1
  shift
  xvfb-run -a -s "-screen 0 2400x1800x24" dbus-run-session -- \
    "$bin/planmeter" --screenshot "$out/linux-$name.png" "$@"
}

shot dashboard-light --size 1200x800 --range today
shot dashboard-dark --size 1200x800 --range today --dark
shot dashboard-week --size 1200x800 --range week
shot narrow --size 400x800 --range today
shot narrow-dark --size 400x800 --range today --dark
shot remote-pairing --size 1200x900 --page remote --pair
shot remote-narrow --size 400x900 --page remote --pair --dark
shot week-hourly --size 1200x800 --range week --action win.granularity::hour
shot accounts --size 1200x800 --page accounts
shot preferences --size 1200x800 --page preferences
shot plan-groups --size 1200x800 --action win.plan-groups --dark
shot no-limit --size 1200x800 --range day
shot revoke --size 1200x800 --page remote --action win.revoke-device::Xk3fQ9vR2mLp8sT1uW4yZa
shot about --size 1200x800 --action app.about
shot unavailable --size 1000x700 --socket /tmp/planmeter-missing/control.sock

# "Start Service" with no systemd user session falls back to planmeterd on
# PATH; here that is the mock, on a runtime dir of its own.
fake=$(mktemp -d)
ln -s "$(cd "$bin" && pwd)/mock-planmeterd" "$fake/planmeterd"
XDG_RUNTIME_DIR=$(mktemp -d) PATH="$fake:$PATH" shot started --size 1000x700 --action win.start-daemon --delay 4000
pkill -f "$fake/planmeterd" 2>/dev/null || true

# A phone "scans" the code after two seconds; the page notices by polling.
runtime=$(mktemp -d)
XDG_RUNTIME_DIR=$runtime "$bin/mock-planmeterd" --auto-pair 2 2>/dev/null &
paired=$!
sleep 0.5
XDG_RUNTIME_DIR=$runtime shot paired --size 1200x900 --page remote --pair --delay 4500
kill $paired 2>/dev/null || true
