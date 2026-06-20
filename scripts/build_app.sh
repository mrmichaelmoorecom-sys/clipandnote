#!/bin/bash
# Build clipandnote.app — bundles the SPM executable and, if present, the
# MobileCLIP model so the shipped app names captures with CLIP labels.
#
#   scripts/build_app.sh [debug|release] [signing-identity]
#
# With no identity it ad-hoc signs for local runs. Pass a Developer ID (and keep
# entitlements.plist for CloudKit) for a distributable build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
IDENTITY="${2:-}"
APP="clipandnote.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/clipandnote"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/clipandnote"

# Bundle the on-device naming model if it's been generated (see README).
if [ -d "Resources/MobileCLIPImage.mlmodelc" ] && [ -f "Resources/clip_labels.json" ]; then
  cp -R "Resources/MobileCLIPImage.mlmodelc" "$APP/Contents/Resources/"
  cp "Resources/clip_labels.json" "$APP/Contents/Resources/"
  echo "  ✓ bundled MobileCLIP model"
else
  echo "  • no MobileCLIP model in Resources/ — naming uses the Vision fallback."
  echo "    Generate it with scripts/export_mobileclip.py (see README)."
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --entitlements entitlements.plist --sign "$IDENTITY" "$APP"
  echo "  signed: $IDENTITY (entitlements applied)"
else
  codesign --force --sign - "$APP"          # ad-hoc — local runs only
  echo "  ad-hoc signed (local). Pass a Developer ID as the 2nd arg for release."
fi

echo "Built $APP"
