#!/usr/bin/env bash
# Builds PlanMeter in release mode and wraps it, the CLI, and the MCP server in
# a signed .app bundle under dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
BUILD_ARCH="${BUILD_ARCH:-arm64}"
APP_NAME="PlanMeter"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

swift build -c "$CONFIG" --arch "$BUILD_ARCH" --product "$APP_NAME"
swift build -c "$CONFIG" --arch "$BUILD_ARCH" --product planmeter-cli
swift build -c "$CONFIG" --arch "$BUILD_ARCH" --product planmeter-mcp
BIN_DIR="$(swift build -c "$CONFIG" --arch "$BUILD_ARCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/planmeter-cli" "$APP/Contents/MacOS/planmeter-cli"
cp "$BIN_DIR/planmeter-mcp" "$APP/Contents/MacOS/planmeter-mcp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Static web client served to browsers over the tailnet.
mkdir -p "$APP/Contents/Resources/Web"
cp "$ROOT/Sources/PlanMeter/Web/"* "$APP/Contents/Resources/Web/"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/scripts/make-icon.py" ]; then
  python3 "$ROOT/scripts/make-icon.py" "$APP/Contents/Resources/AppIcon.icns" || true
fi

# Sign helper executables first, then the bundle itself. Local builds default to
# an ad-hoc signature; release builds can opt into Developer ID signing with:
#   SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" make app
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
  SIGN_ARGS=(--force --sign - --timestamp=none)
  SIGNING_DESCRIPTION="ad-hoc"
else
  SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
  SIGNING_DESCRIPTION="$SIGNING_IDENTITY"
fi

codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/planmeter-cli"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/planmeter-mcp"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP ($SIGNING_DESCRIPTION)"
