#!/usr/bin/env python3
"""
Snap the <path d="..."> data in a menu-bar SVG so every X and Y coordinate
lands on the output @2x pixel grid — including bezier control points.

Path-data snapping is the bit that snap_svg_for_menubar.py (shapes-only)
left on the table. At small output sizes like 60×32, the visual curve
shape barely changes (a few sub-pixel shifts) but stroke alignment
improves noticeably.

Usage:
    python3 scripts/snap_path_data.py [path/to/icon.svg] [out_w] [out_h]
"""
import re, sys, pathlib

src_path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'Resources/menubar-icon4.svg')
OUT_W = int(sys.argv[2]) if len(sys.argv) > 2 else 60
OUT_H = int(sys.argv[3]) if len(sys.argv) > 3 else 32
src = src_path.read_text()

# Parse viewBox from the SVG.
mvb = re.search(r'viewBox="(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)"', src)
if not mvb: raise SystemExit("no viewBox found")
VB_X0, VB_Y0, VB_W, VB_H = (float(mvb.group(i)) for i in range(1, 5))

def snap_x(v): return VB_X0 + round((v - VB_X0) * OUT_W / VB_W) * VB_W / OUT_W
def snap_y(v): return VB_Y0 + round((v - VB_Y0) * OUT_H / VB_H) * VB_H / OUT_H
def fmt(v):    return f"{v:.3f}".rstrip('0').rstrip('.')

# --- Path-data parser ----------------------------------------------------

# Args per command (lowercase). M acts like an L for subsequent implicit args.
ARGS = {'m':2,'l':2,'h':1,'v':1,'c':6,'s':4,'q':4,'t':2,'a':7,'z':0}

TOK = re.compile(r'([MmZzLlHhVvCcSsQqTtAa])|(-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)')

def parse(d):
    """Yield (cmd, args) tuples — implicit-repeat expanded, kept verbatim case."""
    tokens = [(m.group(1) or 'n', m.group(1) or m.group(2)) for m in TOK.finditer(d)]
    i = 0
    cur = None
    while i < len(tokens):
        kind, val = tokens[i]
        if kind != 'n':
            cur = val
            i += 1
            if cur in 'Zz':
                yield (cur, [])
                continue
        n = ARGS[cur.lower()]
        args = []
        for _ in range(n):
            args.append(float(tokens[i][1])); i += 1
        yield (cur, args)
        # Implicit-L after a moveto.
        if cur == 'M': cur = 'L'
        elif cur == 'm': cur = 'l'

def to_absolute(cmds):
    cx = cy = 0.0
    sx = sy = 0.0
    out = []
    for cmd, args in cmds:
        rel = cmd.islower()
        u = cmd.upper()
        if u == 'M':
            x, y = (cx+args[0], cy+args[1]) if rel else (args[0], args[1])
            out.append(('M', [x, y])); cx, cy = x, y; sx, sy = x, y
        elif u == 'L':
            x, y = (cx+args[0], cy+args[1]) if rel else (args[0], args[1])
            out.append(('L', [x, y])); cx, cy = x, y
        elif u == 'H':
            x = cx+args[0] if rel else args[0]
            out.append(('H', [x])); cx = x
        elif u == 'V':
            y = cy+args[0] if rel else args[0]
            out.append(('V', [y])); cy = y
        elif u == 'C':
            if rel:
                x1, y1 = cx+args[0], cy+args[1]
                x2, y2 = cx+args[2], cy+args[3]
                x,  y  = cx+args[4], cy+args[5]
            else:
                x1, y1, x2, y2, x, y = args
            out.append(('C', [x1, y1, x2, y2, x, y])); cx, cy = x, y
        elif u == 'S':
            if rel:
                x2, y2 = cx+args[0], cy+args[1]
                x,  y  = cx+args[2], cy+args[3]
            else:
                x2, y2, x, y = args
            out.append(('S', [x2, y2, x, y])); cx, cy = x, y
        elif u == 'Q':
            if rel:
                x1, y1 = cx+args[0], cy+args[1]
                x,  y  = cx+args[2], cy+args[3]
            else:
                x1, y1, x, y = args
            out.append(('Q', [x1, y1, x, y])); cx, cy = x, y
        elif u == 'T':
            x, y = (cx+args[0], cy+args[1]) if rel else (args[0], args[1])
            out.append(('T', [x, y])); cx, cy = x, y
        elif u == 'A':
            if rel:
                rx, ry, rot, laf, sf, ex, ey = args
                x, y = cx+ex, cy+ey
            else:
                rx, ry, rot, laf, sf, x, y = args
            out.append(('A', [rx, ry, rot, laf, sf, x, y])); cx, cy = x, y
        elif u == 'Z':
            out.append(('Z', [])); cx, cy = sx, sy
    return out

def snap_cmds(cmds):
    """Snap absolute-coord X/Y values; leave radii / flags alone for A."""
    out = []
    for cmd, args in cmds:
        if cmd in ('M', 'L', 'T'):
            out.append((cmd, [snap_x(args[0]), snap_y(args[1])]))
        elif cmd == 'H':
            out.append((cmd, [snap_x(args[0])]))
        elif cmd == 'V':
            out.append((cmd, [snap_y(args[0])]))
        elif cmd == 'C':
            out.append((cmd, [snap_x(args[0]), snap_y(args[1]),
                              snap_x(args[2]), snap_y(args[3]),
                              snap_x(args[4]), snap_y(args[5])]))
        elif cmd in ('S', 'Q'):
            out.append((cmd, [snap_x(args[0]), snap_y(args[1]),
                              snap_x(args[2]), snap_y(args[3])]))
        elif cmd == 'A':
            out.append((cmd, args[:5] + [snap_x(args[5]), snap_y(args[6])]))
        else:                               # Z
            out.append((cmd, []))
    return out

def serialize(cmds):
    parts = []
    for cmd, args in cmds:
        nums = []
        for i, a in enumerate(args):
            s = fmt(a)
            # Add a space before a negative number if it touches the previous one.
            if nums and not s.startswith('-'): nums.append(' ')
            nums.append(s)
        parts.append(cmd + ''.join(nums))
    return ''.join(parts)

# --- Apply to every <path d="..."> in the SVG ---------------------------

def transform_d(d):
    cmds = list(parse(d))
    abs_cmds = to_absolute(cmds)
    snapped = snap_cmds(abs_cmds)
    return serialize(snapped)

paths_seen = 0
def replace_path(m):
    global paths_seen
    paths_seen += 1
    return f'd="{transform_d(m.group(1))}"'

out = re.sub(r'(?<![a-zA-Z])d="([^"]+)"', replace_path, src)
src_path.write_text(out)
print(f"snapped {paths_seen} path(s) in {src_path}  (viewBox {VB_X0:g} {VB_Y0:g} {VB_W:g} {VB_H:g} → {OUT_W}×{OUT_H} grid)")
