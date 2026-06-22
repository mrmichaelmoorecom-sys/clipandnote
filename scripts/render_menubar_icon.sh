#!/bin/bash
# Render Resources/menubar-icon.svg → menubarTemplate PNGs via librsvg
# (a pro SVG renderer with proper coordinate hinting).
#
#   brew install librsvg   # one-time dep
#   scripts/render_menubar_icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "install librsvg: brew install librsvg"; exit 1; }
rsvg-convert -w 28 -h 16 -o Resources/menubarTemplate.png    Resources/menubar-icon.svg
rsvg-convert -w 56 -h 32 -o Resources/menubarTemplate@2x.png Resources/menubar-icon.svg
echo "rendered Resources/menubarTemplate.png (28×16) and @2x.png (56×32)"
