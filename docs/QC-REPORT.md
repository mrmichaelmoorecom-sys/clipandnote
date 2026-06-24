# clipandnote — QC report

Manual QC sweep of the editor window, run per `docs/QC-PLAN.md` against a local
debug build driven through the computer-use MCP. **No code changes were made** —
this is report-and-triage only.

- **Build:** `scripts/build_app.sh debug` — succeeded (40s), ad-hoc signed. One
  compiler warning (see BUG-5).
- **Run:** launched from terminal with stderr → `/tmp/cn-qc.log`. No crashes, no
  stderr output during the entire session.
- **Date:** 2026-06-23. Swift 6.3.1, macOS 26.3 (Command-Line-Tools toolchain).

## 1. Pass/fail by area

| Area | Result | Notes |
|------|--------|-------|
| A. Launch & windows | ✅ PASS | Opens to empty home window; ⌘N opens a 2nd window; ⌘W closes front leaving the other; File menu items + shortcuts correct. Dock-reopen not tested. |
| B. Empty state | ◑ PARTIAL | Open… panel ✅, New Blank Clip ✅. Capture overlay out of scope; drag-image-onto-zone and ⌘V-paste not exercised (see Needs-eyes). |
| C. Draw tools | ✅ PASS | arrow/double-arrow/line/freehand/rect/ellipse/highlighter/text all draw correctly via keyboard **and** toolbar; same-kind hover-grab works (clicking an existing rect with the Rect tool grabbed it instead of stacking). |
| D. Ruler & Angle (focus) | ⚠️ PASS w/ 2 bugs | Core ruler + angle behaviour solid; **BUG-1** (ruler at high width) and **BUG-2** (angle Shift-lock) found. Detail below. |
| E. Color palette + hex | ✅ PASS | Preset → active color + next mark; hex field recolors the selected object, updates the swatch, and fills a custom slot; selecting an object reflects its color back into hex. Eyedropper + custom color-well not tested. |
| F. Per-tool ▼ options | ◑ PARTIAL | Ruler↔Angle toggle ✅; Rect Outline↔Filled ✅; opacity slider present in every tool popover ✅. Text font picker + opacity live-edit not deeply tested. Possible tool-state glitch (BUG-4). |
| G. Selection / move / resize | ✅ PASS | Click-select (8 handles), corner-resize, endpoint reshape (arrow), marquee multi-select, group-move, click-outside deselect all work. Thin-line hit tolerance is tight (minor). |
| H. Layer ordering | ✅ PASS | Send to Back / Bring to Front visibly change z-order (verified at a blue-rect/black-ellipse crossing) via both Arrange menu and ⇧⌘] / ⇧⌘[. Undoable. |
| I. Crop | ✅ PASS | Drag-crop resized canvas 720×560 → 297×345, kept content, footer updated. |
| J. Pixelate | ✅ PASS | Region over image text renders blocky/mosaic. Export/.can survival not separately re-verified. |
| K. OCR (Grab Text) | ✅ PASS | Recognized the text region (dashed box), drag-select + ⌘C put exactly `Esc commit test` on the clipboard. On-device auto-naming also fired (footer named the opened PNG by its text). |
| L. Text editing | ◑ PARTIAL | Esc commits (object persists, selected) ✅; empty text discards ✅. Multi-line, spell-check underline, and font-size changes not exercised. |
| M. Copy / paste | ◑ PARTIAL | Object copy → paste creates an offset duplicate ✅. Copy-with-nothing-selected → flatten-to-PNG not verified (clipboard image can't be read as text). |
| N. Undo / redo | ✅ PASS | ⌘Z / ⇧⌘Z across paste, layering, angle (one undo removes the whole angle). |
| O. Canvas auto-expand | ✅ PASS | Drawing a line past the right edge grew the canvas (297×345 → 768×608) with margin; nothing clipped. |
| P. Export & .can round-trip | ✅ PASS | PNG (594×690 @2x), PDF (1pg), SVG (correct text + filled `<rect>` elements) all valid on disk; `.can` is valid JSON and **reopened** with objects + canvas size intact. |
| Q. Footer | ✅ PASS | Dimensions readout updates on resize and after crop; Share opens the macOS share sheet; brand wordmark is a working clipandnote.com link (see BUG-3 caveat). |

## 2. Bugs (detail)

### BUG-1 — Ruler label + arrowhead balloon at high stroke width (medium)
At large stroke widths the ruler's **"N px" label scales to an enormous font that
overlaps the spine/ticks**, and the **terminal arrowhead becomes disproportionately
huge**, breaking readability. At default/moderate widths the ruler is clean
(graduated major/minor ticks, flat butt caps, arrowhead occluded under the end
cap, upright correct label).
- **Repro:** Ruler tool (M) → push the width slider to max → draw a ruler. Label
  ("467 px" in testing) renders oversized and sits on top of the tick marks; the
  right arrowhead dwarfs the rest. See `/tmp` zoom capture taken during QC.
- **Suspected:** label font size and arrowhead size are tied linearly to stroke
  width with no clamp.

### BUG-2 — Angle Shift-45° lock is ignored when committing a leg (medium)
The plan calls for Shift to lock each angle leg to 45°. It does **not** take effect
on the committing click. A shift-click intended for a 45° leg committed at the raw
cursor angle (measured **32°** in testing).
- **Repro:** Ruler ▼ → Angle. Three-click an angle, holding Shift for the second
  leg → committed angle is not snapped to 45°.
- **Root cause (code-confirmed):** in `CanvasView.swift` the angle mouseDown
  handler sets `points[0] = p` (line ~445) and `points[2] = p` (line ~451) using
  the **raw** point with no Shift check. The 45° constraint (`constrained45`) is
  only applied in the live preview (`angleMouseMoved`, line ~492) and the
  first-leg *drag* path (line ~463) — so the commit click overwrites the snapped
  preview with the unsnapped point. Fix: apply `constrained45` in the awaitingA /
  awaitingB cases too when `.shift` is held.

### BUG-3 — Brand wordmark navigates without a confirm step (low)
Clicking the footer "clipandnote" wordmark opened the URL directly in the default
browser (launched Chrome to clipandnote.com). The plan expected a host
link-confirmation dialog first; none appeared in this session. The link target is
correct (tooltip shows `clipandnote.com`) and benign, but a one-click external
navigation with no confirmation is worth a human decision.

### BUG-4 — Active tool changed unexpectedly after the Rect Filled popover (low, not reproduced)
After toggling Rectangle → Filled in the ▼ popover and dismissing it, the active
tool was observed to have switched to **Text** rather than staying on Rectangle,
so the next drag created a text box instead of a filled rect. Could not cleanly
reproduce (interaction-order sensitive). Flagging for a human to confirm whether
popover dismissal can revert the tool selection.

### BUG-5 — Compiler warning: unused binding (trivial)
`Sources/clipandnote/Document/SVGExporter.swift:120` — `let lw = o.lineWidth, ow =
MarkupRenderer.outlineWidth(o.lineWidth)`; `ow` is never used. Replace with `_`
or drop it to silence the build warning.

## 3. "Needs your eyes" checklist (out-of-scope / visual-only / not exercised)

- **Out of scope (per plan):** menu-bar status dropdown rows; screen-capture
  overlays (crosshair / fullscreen / window grab); notarization/Gatekeeper.
- **Ruler fine detail:** the ≤4px-keeps-weight / >4px ~3× thinner tick boundary
  and the step-up falloff as width grows — ticks visibly thin relative to the
  spine at high width, but the exact px thresholds need a human eye.
- **Angle UX:** with the Angle tool active, *every* click on empty canvas starts a
  new angle — there is no click-to-deselect, which is easy to trip over (it
  confounded one test). Worth confirming this is intended.
- **Not exercised this pass:** ⌘V image paste; drag-image-onto-drop-zone;
  copy-with-nothing-selected → flatten-to-PNG; eyedropper + custom color-well;
  text multi-line / spell-check underline / font-size; pixelate survival through
  export + `.can` round-trip; dock-reopen of a closed window.
- **Minor recurring quirk:** the first click/drag immediately after certain focus
  changes (closing a menu, selecting a tool from the toolbar) is swallowed as a
  refocus — observed on the Open… button and on the first rect draw. Second
  interaction always works. Low severity but slightly papercut-y.
- **Thin-stroke hit tolerance:** selecting a thin line/arrow needs a fairly precise
  click; a slightly larger pick radius would feel better.

## 4. Prioritized bug list

1. **BUG-2** — Angle Shift-45° lock broken on commit (focus feature; code fix is
   small and localized — apply `constrained45` in the awaitingA/awaitingB cases).
2. **BUG-1** — Ruler label/arrowhead oversizing at high stroke width (focus
   feature; clamp label-font and arrowhead size).
3. **BUG-4** — Tool reverts to Text after Rect Filled popover (needs repro).
4. **BUG-3** — Wordmark one-click navigation with no confirm (product decision).
5. **BUG-5** — Unused `ow` binding / build warning (trivial cleanup).

_No code changes were made during QC._
