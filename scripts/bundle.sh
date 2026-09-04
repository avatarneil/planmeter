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
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

swift build -c "$CONFIG" --arch "$BUILD_ARCH" --product "$APP_NAME"
swift build -c "$CONFIG" --arch "$BUILD_ARCH" --product planmeter-cli
swift build -c "$CONFIG" --arch "$BUILD_ARCH" --product planmeter-mcp
BIN_DIR="$(swift build -c "$CONFIG" --arch "$BUILD_ARCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/planmeter-cli" "$APP/Contents/MacOS/planmeter-cli"
cp "$BIN_DIR/planmeter-mcp" "$APP/Contents/MacOS/planmeter-mcp"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE_FRAMEWORK"
cp "$ROOT/.build/checkouts/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
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

# Sparkle's binary framework is universal. Official PlanMeter bundles are
# Apple-Silicon-only, so thin every executable in the copied framework before
# re-signing its nested code from the inside out.
thin_binary() {
  local binary="$1"
  local architectures
  architectures="$(lipo -archs "$binary")"
  case " $architectures " in
    *" $BUILD_ARCH "*) ;;
    *)
      echo "$binary does not contain architecture $BUILD_ARCH" >&2
      exit 1
      ;;
  esac

  if [ "$architectures" != "$BUILD_ARCH" ]; then
    lipo "$binary" -thin "$BUILD_ARCH" -output "$binary.thin"
    mv "$binary.thin" "$binary"
  fi
}

thin_binary "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
thin_binary "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
thin_binary "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
thin_binary "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
thin_binary "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"

# Sign helper executables first, then the bundle itself. Local builds default to
# an ad-hoc signature; release builds can opt into Developer ID signing with:
#   SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" make app
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
  # Hardened Runtime library validation requires a common Team ID, which
  # ad-hoc signatures do not have. Release builds enable it below.
  SIGN_ARGS=(--force --sign - --timestamp=none)
  SIGNING_DESCRIPTION="ad-hoc"
else
  SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
  SIGNING_DESCRIPTION="$SIGNING_IDENTITY"
fi

codesign "${SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/planmeter-cli"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/planmeter-mcp"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP ($SIGNING_DESCRIPTION)"
