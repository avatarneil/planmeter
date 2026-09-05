#!/usr/bin/env bash
# Build the native extension, then sign it before the containing app is signed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
IDENTITY="$2"
CONFIG="$3"
BUILD_ARCH="$4"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
case "$CONFIG" in debug) XCODE_CONFIG=Debug ;; *) XCODE_CONFIG=Release ;; esac
DERIVED="$ROOT/.build/DesktopWidget"
LOG="$ROOT/dist/desktop-widget-build.log"
if ! xcodebuild -quiet -project "$ROOT/macos/PlanMeterDesktopWidget.xcodeproj" \
  -scheme PlanMeterDesktopWidget -configuration "$XCODE_CONFIG" \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  ARCHS="$BUILD_ARCH" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID.desktopwidget" build > "$LOG" 2>&1; then
  tail -100 "$LOG" >&2
  exit 1
fi
mkdir -p "$APP/Contents/PlugIns"
EXTENSION="$APP/Contents/PlugIns/PlanMeterDesktopWidget.appex"
ditto "$DERIVED/Build/Products/$XCODE_CONFIG/PlanMeterDesktopWidget.appex" "$EXTENSION"
TEAM=""
if [ "$IDENTITY" != "-" ]; then
  # The CLI has already been signed by bundle.sh. Read the actual team from
  # its signature so both named and SHA-1 signing identities work.
  TEAM="$(codesign -dv --verbose=4 "$APP/Contents/MacOS/planmeter-cli" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [ -z "$TEAM" ] || [ "$TEAM" = not\ set ]; then
    echo "Desktop widgets require an Apple development team for shared storage." >&2
    exit 1
  fi
fi
python3 - "$APP" "$EXTENSION" "$TEAM" "$ROOT/dist" <<'PY'
import pathlib, plistlib, sys
app, extension, team, dist = map(str, sys.argv[1:])
host_entitlements = {}
widget_entitlements = {'com.apple.security.app-sandbox': True}
if team:
    host_info = pathlib.Path(app) / 'Contents/Info.plist'
    widget_info = pathlib.Path(extension) / 'Contents/Info.plist'
    host = plistlib.loads(host_info.read_bytes())
    widget = plistlib.loads(widget_info.read_bytes())
    group = team + '.' + host['CFBundleIdentifier'] + '.desktop'
    host['PlanMeterAppGroup'] = widget['PlanMeterAppGroup'] = group
    host_info.write_bytes(plistlib.dumps(host, sort_keys=False))
    widget_info.write_bytes(plistlib.dumps(widget, sort_keys=False))
    for entitlements, bundle_id in [(host_entitlements, host['CFBundleIdentifier']), (widget_entitlements, widget['CFBundleIdentifier'])]:
        entitlements['com.apple.security.application-groups'] = [group]
        entitlements['com.apple.application-identifier'] = team + '.' + bundle_id
for name, contents in [('PlanMeter.entitlements', host_entitlements), ('DesktopWidget.entitlements', widget_entitlements)]:
    (pathlib.Path(dist) / name).write_bytes(plistlib.dumps(contents))
PY
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --timestamp=none --entitlements "$ROOT/dist/DesktopWidget.entitlements" "$EXTENSION"
  echo "Desktop widget compiled; live shared data requires a Developer ID or Apple Development signing identity."
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ROOT/dist/DesktopWidget.entitlements" "$EXTENSION"
fi
