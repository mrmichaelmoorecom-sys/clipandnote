#!/usr/bin/env python3
"""
Snap a menu-bar SVG's simple-shape coords so they land on the output @2x
pixel grid — what clipandcue's source effectively did, so the renderer
doesn't bleed strokes across pixel boundaries.

Reads viewBox from the SVG itself; defaults match the active icon. Idempotent
(rounded values that are already on the grid stay put).

Usage:
    python3 scripts/snap_svg_for_menubar.py [path/to/icon.svg] [out_w] [out_h]
"""
import re, sys, pathlib

src_path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'Resources/menubar-icon4.svg')
OUT_W = int(sys.argv[2]) if len(sys.argv) > 2 else 60
OUT_H = int(sys.argv[3]) if len(sys.argv) > 3 else 32
src = src_path.read_text()

m = re.search(r'viewBox="(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)"', src)
if not m: raise SystemExit("no viewBox found")
VB_X0, VB_Y0, VB_W, VB_H = (float(m.group(i)) for i in range(1, 5))

def snap_x(v): return VB_X0 + round((v - VB_X0) * OUT_W / VB_W) * VB_W / OUT_W
def snap_y(v): return VB_Y0 + round((v - VB_Y0) * OUT_H / VB_H) * VB_H / OUT_H
def snap_w(v): return round(v * OUT_W / VB_W) * VB_W / OUT_W
def snap_h(v): return round(v * OUT_H / VB_H) * VB_H / OUT_H
def fmt(v):   return f"{v:.3f}".rstrip('0').rstrip('.')

out = src
def repl_attr(attr, snap):
    return re.compile(rf'(\b{attr}=)"(-?\d+(?:\.\d+)?)"').sub(
        lambda m: f'{m.group(1)}"{fmt(snap(float(m.group(2))))}"', out_local[0])
out_local = [out]
for a, fn in [('x', snap_x), ('cx', snap_x), ('x1', snap_x), ('x2', snap_x),
              ('y', snap_y), ('cy', snap_y), ('y1', snap_y), ('y2', snap_y),
              ('width', snap_w), ('height', snap_h)]:
    out_local[0] = repl_attr(a, fn)

src_path.write_text(out_local[0])
print(f"snapped {src_path}  (viewBox {VB_X0:g} {VB_Y0:g} {VB_W:g} {VB_H:g} → {OUT_W}×{OUT_H} grid)")
