# clipandnote — QC / beta-test plan

A full manual QC sweep of clipandnote's **editor window**, intended to be run by
Claude Code (via the computer-use MCP) on a machine with the app built locally.
Drive the editor window — pick tools, draw, type, click, screenshot-verify each
result — and produce a written QC report. **No code changes during QC** — report
and triage only.

## Ground rules

- **Report only.** Don't fix bugs in this pass; capture them for triage.
- **Non-destructive.** Scratch markups only. Never overwrite real `.can` files,
  never empty trash. Write all test exports/saves to `/tmp`. Cancel out of any
  "save over existing file" dialog.
- **Editor window only.** Two areas are intentionally **out of scope** because a
  computer-use agent can't visually verify them:
  - the **menu-bar status dropdown** — macOS excludes `NSPopover` overlay
    windows from agent screenshots, so the dropdown can't be inspected;
  - the **screen-capture overlays** — crosshair / fullscreen / window grabs spawn
    full-screen capture UI that can't be reliably observed.
  Also out of scope: OCR accuracy on arbitrary content (test behavior only),
  CloudKit / clipandcue interop, and notarization / Gatekeeper (verify with
  `spctl -a -vv clipandnote.app` instead).

## Setup

1. Build a debug build so a crash yields a console trace:
   ```bash
   cd <repo>
   scripts/build_app.sh debug
   ```
2. Launch from a terminal so stderr is captured to a log:
   ```bash
   ./clipandnote.app/Contents/MacOS/clipandnote > /tmp/cn-qc.log 2>&1 &
   ```
   (If a feature crashes, re-run this way and grab the trace from `/tmp/cn-qc.log`.)
3. `request_access` for **clipandnote** (full tier — native third-party app, so
   it's both clickable and typeable).
4. Seed content:
   - **New Blank Clip** (empty-state button) → blank canvas for the vector tools.
   - Open an existing screenshot PNG (any image with UI/text) for tools that need
     a base image: crop, pixelate, OCR.
   - Copy an image to the clipboard, then ⌘V into a blank window to exercise paste.

## Test matrix

For each case: run the action (prefer `computer_batch`), compare to the expected
result, take a screenshot, and record **PASS / FAIL / NEEDS-EYES**. On FAIL,
capture exact repro steps and any `/tmp/cn-qc.log` output.

### A. Launch & windows
- App opens to the empty home window.
- File ▸ New Clip and Note (⌘N) opens a second window.
- Close (⌘W) behaves; reopening via dock works.

### B. Empty state
- **Open…** opens the file panel (cancel it).
- **Capture** triggers (overlay itself is out of scope — just confirm the click
  starts a capture, then Esc out).
- **New Blank Clip** dismisses the overlay → blank white canvas to draw on.
- Drag an image file onto the zone → opens as the base image.
- ⌘V with an image on the clipboard → pastes into the blank canvas.

### C. Draw tools
For each: arrow, double-arrow, line, freehand, rectangle, ellipse, text,
highlighter, pixelate —
- select via toolbar **and** via its keyboard shortcut (A / D / L / P / R / O /
  T / H / X);
- draw on the canvas → correct shape, in the active color;
- hovering an existing same-kind object grabs it instead of stacking a new one.

### D. Ruler & angle (focus area — recently built)
- **Ruler** (M): draw at several stroke widths. Verify: graduated tick hatches,
  the 4px thinness boundary (≤4px keeps weight, above gets ~3× thinner), the
  step-up falloff as width grows, **flat (butt) caps** (no rounded ends), the
  arrowhead sits on the **bottom layer** (end cap + ticks render over it), and
  the **"N px" label** is correct and upright.
- **Angle** (Ruler ▼ → Angle): test **both** interactions —
  - *drag*: press the vertex, drag the first leg, release, sweep, click to set;
  - *three-click*: click vertex, click first-leg end, click second-leg end.
  Verify the live preview between points, the **°** label, **Shift** locking each
  leg to 45°, **undo** removing the whole angle, and **Esc** cancelling mid-build.

### E. Color palette + hex
- Click a preset → active color changes; the drawn mark uses it.
- Pick a custom color via the well → fills the next empty custom slot.
- Eyedropper samples a screen color → fills a slot.
- **Hex field**: type `#RRGGBB` + Return → sets the active color, updates the
  swatch, and recolors the currently-selected object.
- Selecting an existing object reflects its color back into the palette + hex.

### F. Per-tool ▼ options
- Opacity slider: affects the next mark **and** live-edits a selected object's
  alpha; the floating value bubble shows during drag.
- Rectangle / Ellipse: Outline ↔ Filled toggle.
- Text: font-family picker (rendered in each face).
- Ruler: Ruler ↔ Angle toggle.

### G. Selection / move / resize
- Click an object → selected with 8 resize handles + dashed outline.
- Marquee-drag on empty canvas → multi-select; group-move together.
- Drag a corner/edge handle → resizes.
- Endpoint drag on line / arrow / double-arrow / ruler / angle reshapes them.
- Click outside the canvas → deselects (tool stays active). While editing text,
  an outside click **commits** the text first.

### H. Layer ordering
- Bring Forward / Send Backward / Bring to Front / Send to Back change z-order
  visibly; each is undoable.

### I. Crop
- Crop tool → drag a rect → release crops, resizes the canvas, and drops objects
  fully outside the rect. Undoable.

### J. Pixelate
- Draw a pixelate region over image content → renders blocky; survives export +
  `.can` round-trip.

### K. OCR (Grab Text)
- Enter OCR on a text image → recognized regions show; select some + release →
  text copied to clipboard; paste elsewhere to confirm. ⌘A selects all lines.

### L. Text editing
- Place text, type, multi-line (Return = newline), spell-check underline visible,
  Esc commits, empty text discards, font + size changes apply.

### M. Copy / paste
- Copy a selected object → paste re-creates it offset.
- Copy with nothing selected → flattens the canvas to a PNG on the clipboard.

### N. Undo / redo
- Undo/redo across every tool, plus crop, layering, recolor, resize, delete.

### O. Canvas auto-expand
- Move or draw a mark past the snapshot edges → canvas grows with a margin and
  nothing clips.

### P. Export & `.can` round-trip
- Export PNG, PDF, SVG to `/tmp`; open/read each back to confirm it renders
  (the SVG is plain text — sanity-check the elements).
- Save a `.can` to `/tmp`, then File ▸ Open it → objects + layers round-trip.

### Q. Footer
- Dimensions readout updates on window resize and after a crop.
- Share opens the system picker (cancel it).
- The brand wordmark link surfaces the host link-confirmation dialog (don't
  actually navigate).

## Deliverable — QC report

Write the report to chat (and optionally `docs/QC-REPORT.md`):
1. **Pass/fail table** by area A–Q.
2. **Each bug**: severity, repro steps, screenshot, console trace if it crashed.
3. **"Needs your eyes" checklist** — the out-of-scope/visual-only items: the
   menu-bar dropdown rows, the capture flows, and any subtle rendering nits the
   agent flags but can't be certain of.
4. **Prioritized bug list.**

No code changes — the human triages.
