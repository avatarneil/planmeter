#!/usr/bin/env bash
# Runs the Android Gradle build inside Docker so the host needs no JDK or
# Android SDK. Usage, from anywhere in the repository:
#
#   android/scripts/docker-gradle.sh :protocol:test :app:assembleDebug
#
# The image is linux/amd64 because Android's aapt2 ships no linux-arm64 build;
# Apple silicon hosts run it under Rosetta (OrbStack) or QEMU. The SDK and the
# Gradle cache live in named volumes, so only the first run downloads them.
set -euo pipefail

android_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$android_dir/.." && pwd)"

image="${PLANMETER_ANDROID_IMAGE:-eclipse-temurin:21-jdk-noble}"
sdk_volume="${PLANMETER_ANDROID_SDK_VOLUME:-planmeter-android-sdk}"
gradle_volume="${PLANMETER_ANDROID_GRADLE_VOLUME:-planmeter-android-gradle}"

if [[ $# -eq 0 ]]; then
  set -- :protocol:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
fi

tty=()
[[ -t 0 && -t 1 ]] && tty=(-it)

# The whole repository is mounted so tests can read the shared protocol
# fixtures in ../protocol.
exec docker run --rm ${tty[@]+"${tty[@]}"} \
  --platform linux/amd64 \
  --name "planmeter-android-gradle-$$" \
  -v "$repo_dir":/work \
  -v "$sdk_volume":/opt/android-sdk \
  -v "$gradle_volume":/root/.gradle \
  -e ANDROID_HOME=/opt/android-sdk \
  -e PLANMETER_INTEROP_PAIR_URL \
  -e GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.vfs.watch=false" \
  -w /work/android \
  "$image" \
  bash -c 'scripts/ensure-android-sdk.sh && ./gradlew --console=plain "$@"' gradle "$@"
