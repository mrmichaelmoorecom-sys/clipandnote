#!/bin/bash
# Render Resources/menubar-icon.svg → menubarTemplate PNGs via librsvg
# (a pro SVG renderer with proper coordinate hinting).
#
#   brew install librsvg   # one-time dep
#   scripts/render_menubar_icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "install librsvg: brew install librsvg"; exit 1; }
# Source: menubar-icon2.svg — the paperclip mark (viewBox 380.5 × 205, ~1.856:1).
# StatusItemController re-renders these to exact Retina device pixels at runtime
# with imageInterpolation = .none, so a slightly oversized source asset is fine.
SRC=Resources/menubar-icon4.svg
rsvg-convert -w 30 -h 16 -o Resources/menubarTemplate.png    "$SRC"
rsvg-convert -w 60 -h 32 -o Resources/menubarTemplate@2x.png "$SRC"
echo "rendered Resources/menubarTemplate.png (30×16) and @2x.png (60×32) from $SRC"
