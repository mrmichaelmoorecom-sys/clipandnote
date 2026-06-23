#!/bin/bash
# Notarize clipandnote.app via Apple's notary service and staple the ticket.
#
#   scripts/notarize.sh [keychain-profile-name]
#
# Prereqs (one-time):
#   1. Get an app-specific password at https://appleid.apple.com → Sign-In &
#      Security → App-Specific Passwords.
#   2. Store credentials in the keychain so this script can use them:
#
#        xcrun notarytool store-credentials clipandnote-notary \
#          --apple-id "mike@mrmichaelmoore.com" \
#          --team-id  "HA5AB7JS87" \
#          --password "<the app-specific password>"
#
# Then for each release:
#   scripts/build_app.sh release "Developer ID Application: Michael Moore (HA5AB7JS87)"
#   scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-clipandnote-notary}"
APP="clipandnote.app"
ZIP="clipandnote.zip"

if [ ! -d "$APP" ]; then
  echo "✘ $APP not found. Build it first with scripts/build_app.sh release '<identity>'."
  exit 1
fi

# Refuse to submit an ad-hoc signed build — Apple rejects those instantly.
# (Don't use `awk {exit}` here — it closes the pipe early and SIGPIPEs
# codesign, which pipefail then turns into a script-killing non-zero exit.)
auth=$(codesign -dvv "$APP" 2>&1 | grep -m1 '^Authority=Developer ID' || true)
if [ -z "$auth" ]; then
  echo "✘ $APP isn't signed with a Developer ID cert. Re-build with:"
  echo "   scripts/build_app.sh release 'Developer ID Application: Michael Moore (HA5AB7JS87)'"
  exit 1
fi

echo "→ Zipping $APP for submission…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Submitting to Apple's notary service (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "→ Stapling ticket to $APP…"
xcrun stapler staple "$APP"

echo "→ Verifying staple + Gatekeeper acceptance…"
xcrun stapler validate "$APP"
spctl -avvv "$APP"

rm -f "$ZIP"
echo "✓ $APP is notarized and stapled."
