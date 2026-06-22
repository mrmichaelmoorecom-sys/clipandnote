#!/usr/bin/env python3
"""
Snap Resources/menubar-icon.svg coords so the simple shapes (rect, lines)
land on the output @2x pixel grid (56×32). This is what clipandcue's source
must have done — same render path, just SVG numbers that round cleanly.

Strategy: at 56-wide output the viewBox-to-pixel ratio is 362/56 ≈ 6.464 (x)
and 205/32 ≈ 6.406 (y). Snap each rect/line coord to the nearest input value
that lands at an integer output pixel. Also normalise strokes to a clean 2px
(stroke-width = 13 ≈ 2.01px at 56-wide output).
"""
import re, pathlib

src = pathlib.Path('Resources/menubar-icon.svg').read_text()
VB_X0, VB_Y0, VB_W, VB_H = 82, 167, 362, 205
OUT_W, OUT_H = 56, 32

def snap_x(v): return VB_X0 + round((v - VB_X0) * OUT_W / VB_W) * VB_W / OUT_W
def snap_y(v): return VB_Y0 + round((v - VB_Y0) * OUT_H / VB_H) * VB_H / OUT_H
def snap_w(v): return round(v * OUT_W / VB_W) * VB_W / OUT_W
def snap_h(v): return round(v * OUT_H / VB_H) * VB_H / OUT_H
def fmt(v):   return f"{v:.3f}".rstrip('0').rstrip('.')

# All strokes → 13 (≈2px at 56-wide; matches clipandcue's 2px appearance)
out = re.sub(r'stroke-width="\d+(?:\.\d+)?"', 'stroke-width="13"', src)

def repl_attr(attr, snap):
    return re.compile(rf'(\b{attr}=)"(-?\d+(?:\.\d+)?)"').sub(
        lambda m: f'{m.group(1)}"{fmt(snap(float(m.group(2))))}"', out_local[0])
out_local = [out]
for a, fn in [('x', snap_x), ('cx', snap_x), ('x1', snap_x), ('x2', snap_x),
              ('y', snap_y), ('cy', snap_y), ('y1', snap_y), ('y2', snap_y),
              ('width', snap_w), ('height', snap_h)]:
    out_local[0] = repl_attr(a, fn)

pathlib.Path('Resources/menubar-icon.svg').write_text(out_local[0])
print("snapped Resources/menubar-icon.svg")
