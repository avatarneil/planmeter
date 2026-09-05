#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/dist/PlanMeter.app"
ARCHIVE_NAME="PlanMeter-v${VERSION}-macos-arm64.zip"
ARCHIVE="$ROOT/dist/$ARCHIVE_NAME"
CHECKSUM="$ARCHIVE.sha256"
NOTARY_PROFILE="${NOTARY_PROFILE:-planmeter-notary}"
APPCAST_DIR="$ROOT/dist/appcast"
APPCAST="$ROOT/dist/appcast.xml"
SPARKLE_TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

if [ -z "${SIGNING_IDENTITY:-}" ]; then
  echo "Set SIGNING_IDENTITY to a Developer ID Application identity." >&2
  exit 1
fi

"$ROOT/scripts/check-version.sh"
swift package resolve
if [ ! -x "$SPARKLE_TOOLS/generate_appcast" ]; then
  echo "Sparkle release tools were not resolved under .build." >&2
  exit 1
fi

EXPECTED_SPARKLE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Resources/Info.plist")"
KEYCHAIN_SPARKLE_KEY="$("$SPARKLE_TOOLS/generate_keys" -p)"
if [ "$KEYCHAIN_SPARKLE_KEY" != "$EXPECTED_SPARKLE_KEY" ]; then
  echo "The Sparkle private key in Keychain does not match Resources/Info.plist." >&2
  exit 1
fi

BUILD_ARCH=arm64 SIGNING_IDENTITY="$SIGNING_IDENTITY" "$ROOT/scripts/bundle.sh"

# Keep AppleDouble metadata outside the signed .app. Some extractors leave
# inline ._ sidecars beside framework symlinks, breaking Gatekeeper validation.
rm -f "$ARCHIVE" "$CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# ZIP archives cannot themselves be stapled, so recreate the archive from the
# stapled app and publish a checksum alongside it.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
"$ROOT/scripts/verify-release-archive.sh" "$ARCHIVE"
(
  cd "$ROOT/dist"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$ARCHIVE" "$APPCAST_DIR/$ARCHIVE_NAME"
"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/avatarneil/planmeter/releases/download/v${VERSION}/" \
  --link "https://github.com/avatarneil/planmeter" \
  --maximum-versions 1 \
  "$APPCAST_DIR"
cp "$APPCAST_DIR/appcast.xml" "$APPCAST"

echo "Release artifacts:"
echo "  $ARCHIVE"
echo "  $CHECKSUM"
echo "  $APPCAST"
