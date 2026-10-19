#!/usr/bin/env bash
# Builds or tests the portable Swift targets on Linux inside Docker.
#
#   scripts/linux/run.sh build|test [extra swift arguments]
#   scripts/linux/run.sh smoke
#
# `smoke` builds planmeterd and runs scripts/linux/smoke-planmeterd.sh in the
# container: the control API over the Unix socket, a paired client over
# loopback, and a clean shutdown. PLANMETER_LINUX_DOCKER_ARGS adds `docker run`
# arguments, for example `--network none` or read-only provider homes plus
# `-e PLANMETER_SMOKE_HOME=…` to scan real transcripts.
#
# The checkout is streamed into the container and mirrored into a named
# volume, so the Linux build never touches the macOS .build directory or
# rewrites the checked-in Package.resolved (Linux resolves swift-crypto
# instead of Sparkle). Streaming with tar, rather than bind-mounting the
# checkout, also avoids stale file metadata right after an edit.
set -euo pipefail

cd "$(dirname "$0")/../.."
image="${PLANMETER_LINUX_IMAGE:-planmeter-linux-swift:6.2}"
volume="${PLANMETER_LINUX_VOLUME:-planmeter-linux-build}"
command="${1:-build}"
shift || true

docker build -q -t "$image" scripts/linux >/dev/null

# --checksum keeps unchanged files (and their build products) untouched.
sync='mkdir -p /tmp/incoming && tar -xf - -C /tmp/incoming && rsync -a --checksum --delete --exclude=/Package.resolved /tmp/incoming/ /work/src/'
swift_args='--package-path /work/src --scratch-path /work/build'

case "$command" in
  build) script="$sync && swift build $swift_args $*" ;;
  test) script="$sync && swift test $swift_args $*" ;;
  smoke) script="$sync && swift build $swift_args --build-tests && /work/src/scripts/linux/smoke-planmeterd.sh" ;;
  *) echo "usage: $0 build|test|smoke [swift arguments]" >&2; exit 2 ;;
esac

COPYFILE_DISABLE=1 tar -cf - --no-xattrs \
  --exclude=./.build --exclude=./.git --exclude=./.swiftpm --exclude=./dist \
  --exclude=./ios --exclude=./macos --exclude=./Package.resolved . |
  docker run --rm -i -v "$volume":/work ${PLANMETER_LINUX_DOCKER_ARGS:-} "$image" bash -c "$script"
