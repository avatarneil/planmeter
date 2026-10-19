#!/bin/sh
# Runs a command in the planmeter-linux-dev image (Debian trixie: GTK 4.18,
# libadwaita 1.7) with linux/ mounted at /src/linux. Cargo's registry and
# target directory live in named volumes, so the host tree stays clean.
#
#   docker/dev.sh cargo test
#   SHOTS=/tmp/planmeter-shots docker/dev.sh docker/screenshots.sh
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
docker build -q -t planmeter-linux-dev -f "$here/docker/Dockerfile" "$here/docker" >/dev/null
exec docker run --rm \
  -v "$here":/src/linux \
  -v planmeter-cargo-registry:/usr/local/cargo/registry \
  -v planmeter-linux-target:/target -e CARGO_TARGET_DIR=/target \
  ${SHOTS:+-v "$SHOTS":/shots} \
  planmeter-linux-dev "$@"
