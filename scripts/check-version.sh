#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")"

if [ -z "$VERSION" ]; then
  echo "VERSION is empty" >&2
  exit 1
fi

if [ -z "$BUILD_NUMBER" ]; then
  echo "BUILD_NUMBER is empty" >&2
  exit 1
fi

MAC_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
if [ "$MAC_VERSION" != "$VERSION" ]; then
  echo "Resources/Info.plist is $MAC_VERSION; expected $VERSION" >&2
  exit 1
fi

MAC_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
if [ "$MAC_BUILD" != "$BUILD_NUMBER" ]; then
  echo "Resources/Info.plist build is $MAC_BUILD; expected $BUILD_NUMBER" >&2
  exit 1
fi

if ! grep -Fq "let serverVersion = \"$VERSION\"" "$ROOT/Sources/PlanMeterMCP/main.swift"; then
  echo "Sources/PlanMeterMCP/main.swift does not use version $VERSION" >&2
  exit 1
fi

IOS_VERSIONS="$(grep -E 'MARKETING_VERSION = ' "$ROOT/ios/PlanMeterMobile/PlanMeterMobile.xcodeproj/project.pbxproj" || true)"
if [ -z "$IOS_VERSIONS" ]; then
  echo "No iOS or watchOS marketing versions found" >&2
  exit 1
fi

if printf '%s\n' "$IOS_VERSIONS" | grep -Fv "MARKETING_VERSION = $VERSION;" >/dev/null; then
  echo "An iOS or watchOS target does not use version $VERSION" >&2
  exit 1
fi

IOS_BUILDS="$(grep -E 'CURRENT_PROJECT_VERSION = ' "$ROOT/ios/PlanMeterMobile/PlanMeterMobile.xcodeproj/project.pbxproj" || true)"
if [ -z "$IOS_BUILDS" ]; then
  echo "No iOS or watchOS build numbers found" >&2
  exit 1
fi

if printf '%s\n' "$IOS_BUILDS" | grep -Fv "CURRENT_PROJECT_VERSION = $BUILD_NUMBER;" >/dev/null; then
  echo "An iOS or watchOS target does not use build number $BUILD_NUMBER" >&2
  exit 1
fi

echo "All release versions are $VERSION ($BUILD_NUMBER)"
