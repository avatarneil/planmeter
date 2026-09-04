#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/dist/PlanMeter.app"
ARCHIVE_NAME="PlanMeter-v${VERSION}-macos-arm64.zip"
ARCHIVE="$ROOT/dist/$ARCHIVE_NAME"
CHECKSUM="$ARCHIVE.sha256"
NOTARY_PROFILE="${NOTARY_PROFILE:-planmeter-notary}"

if [ -z "${SIGNING_IDENTITY:-}" ]; then
  echo "Set SIGNING_IDENTITY to a Developer ID Application identity." >&2
  exit 1
fi

"$ROOT/scripts/check-version.sh"
BUILD_ARCH=arm64 SIGNING_IDENTITY="$SIGNING_IDENTITY" "$ROOT/scripts/bundle.sh"

rm -f "$ARCHIVE" "$CHECKSUM"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# ZIP archives cannot themselves be stapled, so recreate the archive from the
# stapled app and publish a checksum alongside it.
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
(
  cd "$ROOT/dist"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "Release artifacts:"
echo "  $ARCHIVE"
echo "  $CHECKSUM"
