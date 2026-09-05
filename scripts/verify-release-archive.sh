#!/usr/bin/env bash
# Verify the final release ZIP through metadata-aware and ordinary ZIP extraction.
set -euo pipefail
ARCHIVE="$1"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/planmeter-archive-check.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
python3 - "$ARCHIVE" <<'PY'
import pathlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    for name in names:
        path = pathlib.PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts:
            raise SystemExit(f'Unsafe archive path: {name}')
        if name.startswith('PlanMeter.app/') and path.name.startswith('._'):
            raise SystemExit(f'Inline AppleDouble metadata breaks code signing: {name}')
    if 'PlanMeter.app/Contents/Info.plist' not in names:
        raise SystemExit('Archive does not contain PlanMeter.app')
PY
ditto -x -k "$ARCHIVE" "$TEMP_DIR/ditto"
unzip -q "$ARCHIVE" -d "$TEMP_DIR/unzip"
for EXTRACTOR in ditto unzip; do
  APP="$TEMP_DIR/$EXTRACTOR/PlanMeter.app"
  codesign --verify --deep --strict "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
done
echo 'Release ZIP passes Gatekeeper after both ditto and unzip extraction.'
