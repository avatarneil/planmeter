#!/usr/bin/env bash
# Installs the Android command-line tools and the packages this project builds
# against into $ANDROID_HOME, accepting licenses on the way. Idempotent: a
# populated SDK (a Docker volume, or a CI runner's preinstalled SDK) is reused.
set -euo pipefail

: "${ANDROID_HOME:?Set ANDROID_HOME to the SDK directory}"

# Keep in sync with android/gradle/libs.versions.toml (compileSdk, buildTools).
CMDLINE_TOOLS_BUILD="${CMDLINE_TOOLS_BUILD:-16111833}"
PACKAGES=(
  "platforms;android-37.0"
  "build-tools;37.0.0"
)

sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [[ ! -x "$sdkmanager" ]]; then
  echo "Installing Android command-line tools ($CMDLINE_TOOLS_BUILD) into $ANDROID_HOME"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/tools.zip" "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip"
  mkdir -p "$tmp/x" "$ANDROID_HOME/cmdline-tools"
  # The JDK image has no unzip; jar extracts but drops the executable bits.
  (cd "$tmp/x" && jar xf "$tmp/tools.zip")
  chmod +x "$tmp/x/cmdline-tools/bin/"*
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$tmp/x/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$tmp"
fi

missing=()
for package in "${PACKAGES[@]}"; do
  dir="$ANDROID_HOME/${package//;//}"
  [[ -d "$dir" ]] || missing+=("$package")
done

if (( ${#missing[@]} > 0 )); then
  yes | "$sdkmanager" --licenses > /dev/null || true
  echo "Installing ${missing[*]}"
  "$sdkmanager" --install "${missing[@]}" > /dev/null
fi
