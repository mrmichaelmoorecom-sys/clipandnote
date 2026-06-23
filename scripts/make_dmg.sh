#!/usr/bin/env bash
# Build a drag-to-Applications .dmg for clipandnote, then sign + notarize +
# staple it. After this, the .dmg is fully Gatekeeper-clean — drag-anywhere
# downloads launch with no warning on a fresh Mac.
#
# Run scripts/build_app.sh release "Developer ID …" first so clipandnote.app
# exists, is signed with the Developer ID cert, and (ideally) already
# notarized + stapled. Then:
#
#   scripts/make_dmg.sh                       # build, sign, notarize, staple
#   scripts/make_dmg.sh --no-notarize         # build + sign only (faster iteration)
#
# Profile name for notarytool defaults to `clipandnote-notary` (same as
# scripts/notarize.sh) — store creds once with `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
APP_NAME="clipandnote"
APP="$ROOT/$APP_NAME.app"
VOL="clipandnote"
DMG_FINAL="$ROOT/$APP_NAME.dmg"
BG_PNG="$ROOT/Resources/dmg-background.png"
BG_TIFF="$ROOT/Resources/dmg-background.tiff"
IDENTITY="Developer ID Application: Michael Moore (HA5AB7JS87)"
PROFILE="clipandnote-notary"
NOTARIZE=1

for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
  esac
done

[[ -d "$APP" ]] || { echo "error: $APP not found — run scripts/build_app.sh release '$IDENTITY' first" >&2; exit 1; }

# Regenerate the background PNG → TIFF if the source script changed or the
# TIFF isn't there yet. Cheap — takes <1s.
if [[ ! -f "$BG_TIFF" || "$ROOT/scripts/make_dmg_bg.swift" -nt "$BG_TIFF" ]]; then
  echo "==> generating DMG background"
  swift "$ROOT/scripts/make_dmg_bg.swift" "$BG_PNG" 2 >/dev/null
  sips -s format tiff "$BG_PNG" --out "$BG_TIFF" >/dev/null
fi

# Detach any stale mount of the same volume.
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true

WORK="$(mktemp -d)"
STAGING="$WORK/stage"
TMP_DMG="$WORK/rw.dmg"
mkdir -p "$STAGING"

echo "==> staging contents"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$BG_TIFF" "$STAGING/.background/background.tiff"

SIZE_MB=$(( $(du -sk "$STAGING" | cut -f1) / 1024 + 30 ))

echo "==> creating writable image (${SIZE_MB}m)"
hdiutil create -srcfolder "$STAGING" -volname "$VOL" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" -ov "$TMP_DMG" >/dev/null

echo "==> mounting"
hdiutil attach "$TMP_DMG" -noautoopen -mountpoint "/Volumes/$VOL" >/dev/null
sleep 1

echo "==> arranging window (Finder)"
osascript <<APPLESCRIPT || echo "WARN: Finder layout step returned an error (above). Grant Automation → Finder if prompted, then re-run."
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 180, 960, 608}
    set theOptions to the icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 128
    set text size of theOptions to 13
    set background picture of theOptions to file ".background:background.tiff"
    -- Position by name match — the .app extension is hidden so exact matches miss.
    repeat with anItem in (get items of container window)
      set nm to name of anItem
      if nm contains "clipandnote" then
        set position of anItem to {165, 200}
      else if nm is "Applications" then
        set position of anItem to {495, 200}
      else
        set position of anItem to {1600, 1600}
      end if
    end repeat
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
echo "==> detaching"
hdiutil detach "/Volumes/$VOL" >/dev/null || hdiutil detach "/Volumes/$VOL" -force >/dev/null

echo "==> compressing to read-only $DMG_FINAL"
rm -f "$DMG_FINAL"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -rf "$WORK"

echo "==> signing DMG with $IDENTITY"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DMG_FINAL"

if [[ "$NOTARIZE" -eq 1 ]]; then
  echo "==> submitting DMG to Apple notary service (profile: $PROFILE)…"
  xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$PROFILE" --wait
  echo "==> stapling ticket to DMG"
  xcrun stapler staple "$DMG_FINAL"
  echo "==> verifying"
  xcrun stapler validate "$DMG_FINAL"
  spctl -a -t open --context context:primary-signature -vv "$DMG_FINAL" 2>&1 | sed 's/^/    /'
fi

echo "==> done: $DMG_FINAL ($(du -h "$DMG_FINAL" | cut -f1))"
