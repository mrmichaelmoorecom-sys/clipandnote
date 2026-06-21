#!/bin/bash
# Quick local bench: build and run clipandnote straight from the SPM build dir.
#
#   scripts/run.sh            # normal launch
#   scripts/run.sh --release  # optimized build
#   CLIPANDNOTE_DEMO=1 scripts/run.sh   # open a seeded demo editor
#
# Unlike build_app.sh this does NOT wrap the binary in a freshly ad-hoc-signed
# .app, so macOS keeps recognizing it as the same program — no re-granting
# Screen Recording / Accessibility (or re-clearing Gatekeeper) on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="debug"
if [ "${1:-}" = "--release" ]; then CONFIG="release"; shift; fi

swift build -c "$CONFIG"
exec ".build/$CONFIG/clipandnote" "$@"
