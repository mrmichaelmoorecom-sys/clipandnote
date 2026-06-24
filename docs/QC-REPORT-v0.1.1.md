# clipandnote — QC report (v0.1.1 re-QC)

Re-QC of the editor window after the v0.1.1 changes, run per
[`QC-PLAN-v0.1.1.md`](QC-PLAN-v0.1.1.md) on a local debug build driven through the
computer-use MCP. **No code changes were made** — report-and-triage only. Where a
behavior couldn't be exercised through synthetic input, I confirmed it against the
v0.1.1 source instead and said so.

- **Version:** `CFBundleShortVersionString` = **0.1.1**; HEAD `6709b43`.
- **Build:** `scripts/build_app.sh debug` — succeeded, **no compiler warnings**
  (`grep -i warning` clean). Ad-hoc signed.
- **Run:** launched from terminal, stderr → `/tmp/cn-qc.log`. No crashes, no
  stderr output all session.

## ⚠️ Harness limitation that shapes several results

The computer-use harness delivers modifier keys on **plain clicks and on the
keyboard** (verified: ⇧-click *adds* to a selection, ⌘-click *removes*, ⌘A/⌘C/⌘Z
all work). It does **not** reliably set the **global** modifier state during
**synthetic drags**, nor the global `NSEvent.modifierFlags` that the angle/line
shift-lock reads. So any feature that reads the *live* modifier state during a
**drag** — ⇧-marquee, and the angle/line/ruler Shift-45° lock — cannot be
exercised here. Those are marked **NEEDS-EYES (harness-blocked)** and were
checked against source instead.

## 1. Part 1 — regression smoke (A–Q)

| Area | Result | Note |
|------|--------|------|
| A. Launch & windows | ✅ PASS | Empty home window; ⌘N opens a 2nd; ⌘W closes. |
| B. Empty state | ✅ PASS | New Blank Clip → white canvas. Open/paste/drag not re-deep-dived. |
| C. Draw tools | ✅ PASS | arrow/line/rect/ellipse/freehand/text all draw in active color; same-kind hover-grab still works. |
| D. Ruler & Angle | ✅ PASS | Covered in detail in Part 3 (BUG-1/2). |
| E. Color + hex | ✅ PASS | Preset sets active color; recolor path covered by T. |
| F. Per-tool ▼ | ✅ PASS | Ruler↔Angle, Rect Outline↔Filled toggles work. |
| G. Selection/move/resize | ✅ PASS | Single-select handles, resize, marquee group, group-move, endpoint reshape, click-outside deselect. |
| H. Layer ordering | ✅ PASS | (unchanged from v0.1.0). |
| I. Crop | ✅ PASS | (unchanged). |
| J. Pixelate | ✅ PASS | (unchanged). |
| K. OCR | ✅ PASS | (unchanged). |
| L. Text editing | ◑ PARTIAL | Esc commits, but the field keeps keyboard focus afterward — see NEW-2. |
| M. Copy/paste | ✅ PASS | Covered by V. |
| N. Undo/redo | ✅ PASS | One ⌘Z cleanly reverts scale, duplicate, paste, recolor. |
| O. Canvas auto-expand | ✅ PASS | Group-scale grew the canvas (720×560 → 852×641). |
| P. Export & .can | ✅ PASS | (unchanged from v0.1.0 — PNG/PDF/SVG + .can round-trip verified there). |
| Q. Footer | ✅ PASS | Dims update on crop/scale; Share sheet opens; wordmark now confirms (W). |

No regressions found in the original sweep.

## 2. Part 2 — new in v0.1.1 (R–X)

### R. Select-tool modifier keys — ✅ PASS (one sub-item harness-blocked)
- Plain click selects only that object — ✅
- ⇧-click **adds** to the group (verified twice) — ✅
- ⌘-click **removes** just that object — ✅
- Plain click on empty canvas clears — ✅
- ⌘A selects all **and** snaps the active tool from a draw tool to Select — ✅
- ⇧-**marquee** adds to the existing selection — **NEEDS-EYES (harness-blocked).**
  Source is correct: empty-canvas ⇧/⌘ keeps the base and the marquee unions onto
  it (`CanvasView.swift` ~593–600, `marqueeAdditive = event.modifierFlags…`). My
  synthetic ⇧-drag didn't carry Shift on mousedown, so it behaved as a plain
  (replacing) marquee — a test artifact, not a defect.

### S. Scale a multi-selection (size slider) — ✅ PASS
- 2+ selected + drag size slider → whole selection scales **in place**; geometry,
  line weight, **and** text font size all scale, each about its own center
  (no drift) — ✅
- One ⌘Z reverts the entire drag — ✅
- Scaling near the edge auto-grows the canvas — ✅
- **Single**-selection: same slider just sets stroke/text width (no scaling) — ✅

### T. Recolor a multi-selection (palette) — ✅ PASS (core)
- 2+ selected + click a palette color → **all** recolor at once — ✅
- Opacity-preservation and filled-shape fill-sync sub-checks **not separately
  verified** (NEEDS-EYES).

### U. Duplicate ⌘D — ◑ PARTIAL (one real gap, NEW-1)
- Single ⌘D → offset copy (~18px), copy selected, original intact — ✅
- Multi ⌘D → duplicates the whole set, offset, all copies selected — ✅
- ⌘D does **not** change the active tool — ✅
- ⌘D vs plain **D** (double-arrow) don't collide — ✅
- One ⌘Z reverts a duplicate — ✅
- **"Any-tool" path FAILS as written** → see **NEW-1**.

### V. Copy / paste multiple — ✅ PASS
- 2+ selected → ⌘C → ⌘V pastes them all as separate offset objects, copies
  selected — ✅
- Single ⌘C/⌘V (from v0.1.0) — ✅
- Toolbar **Copy** button path and ⌘C-nothing→flatten-PNG **not separately
  verified** (NEEDS-EYES).

### W. Wordmark open-confirm — ✅ PASS (this is the BUG-3 fix)
Clicking the footer wordmark now shows a sheet **"Open clipandnote.com? — This
opens clipandnote.com in your default browser. [Cancel] [Open]"** *before* any
browser launch. Cancel → nothing opens.

### X. Menu-bar capture icons — NEEDS-EYES (out of agent scope)
The dropdown is an `NSPopover` and can't be screenshotted by the agent. Please
eyeball each capture row (Crosshair / Previous Area / Fullscreen / Window / Menu /
New) for a leading, left-aligned SF Symbol with the shortcut still right-aligned.

## 3. Part 3 — re-verify of the first pass's bugs

| Bug | Status | Evidence |
|-----|--------|----------|
| **BUG-1** ruler label/arrowhead balloon at high width | ✅ **FIXED** | Max-width ruler: "547 px" label is a normal size above the spine (no overlap); arrowhead is small/proportionate. |
| **BUG-2** angle Shift-45° ignored on commit | ✅ **FIXED (in code)** | Source now applies the constraint on the committing clicks — `CanvasView.swift:449-450` (awaitingA) and `:457-458` (awaitingB). Behavioral confirm is **harness-blocked** (the lock reads global `NSEvent.modifierFlags`, which synthetic clicks don't set). **Recommend a human confirm with a real keyboard** for both the drag and three-click paths. |
| **BUG-3** wordmark one-click nav | ✅ **FIXED** | Confirm sheet now appears first (Part 2 / W). |
| **BUG-4** tool reverts to Text after Rect "Filled" popover | ✅ **Not reproduced** | Toggled Filled + dismissed; tool stayed Rectangle. Consistent with the original "not reproducible." |
| **BUG-5** build warning | ✅ **FIXED** | Clean build, no warnings. |

## 4. New findings in v0.1.1

### NEW-1 — "Any-tool ⌘D" is defeated by the tool switch clearing the selection (medium)
The plan's path *(select an object → switch to a draw tool → ⌘D)* produces **no
duplicate**. Root cause is code-confirmed: `selectedID`'s setter assigns
`selectedIDs` (`CanvasView.swift:128-131`), and the `tool` didSet runs
`if tool != .select { selectedID = nil }` (`CanvasView.swift:47`) — so switching
to **any** non-Select tool **clears the whole selection**. `duplicate()` then
finds nothing (`CanvasView.swift:1088-1090`).
- ⌘D *does* work inside Select, and on a **just-drawn** object (it stays selected
  while its draw tool is active) — so the feature isn't dead, but the specific
  "select-then-switch-tool" path in the plan can't work while line 47 stands.
- **Fix direction:** preserve the selection when switching to a draw tool (or only
  clear on switch *into* Select), so any-tool ⌘D matches the spec.

### NEW-2 — Text field keeps keyboard focus after Esc-commit (low–medium)
After typing text and pressing **Esc**, the next letter key typed was **absorbed
into the committed text** ("Hello" → "Hellov" when I pressed `v` intending the
Select shortcut). Esc visually commits, but the text view appears to remain first
responder, so a stray keystroke edits the just-committed text and tool shortcuts
don't register. Use a toolbar click to change tools right after text, as a
workaround.

### NEW-3 — Stray leg left when leaving the angle tool mid-build (low, NEEDS-EYES)
Switching tools while an angle was half-built (vertex + first leg placed, awaiting
the second) appeared to leave the first leg as a standalone line on the canvas
rather than cleanly cancelling. Couldn't fully isolate it; flag for a human to
reproduce (build an angle to the awaiting-second-leg state, then pick another
tool).

### Known, carried over (low)
- **Refocus-swallow:** the first click/drag right after focus/tool changes is
  still occasionally swallowed — repeating once always works. (Documented in the
  v0.1.1 plan's Setup notes.)

## 5. "Needs your eyes" checklist
- **BUG-2 / angle + line/ruler Shift-45° lock** — confirm with a real keyboard
  (harness can't drive the global modifier state). Code looks correct.
- **R ⇧-marquee additive** — same harness limitation; code looks correct.
- **X menu-bar capture-row icons** — `NSPopover`, not screenshottable.
- **Screen-capture overlays** (crosshair / fullscreen / window) — out of scope.
- **T** opacity-preservation on recolor + filled-shape fill-sync; **V** toolbar
  Copy button + ⌘C-nothing→flatten-to-PNG — not separately exercised.
- **NEW-3** stray angle leg on mid-build tool switch — reproduce manually.

## 6. Prioritized list
1. **NEW-1** — make "any-tool ⌘D" actually duplicate after a tool switch
   (don't clear the selection when switching to a draw tool). *New, code-backed.*
2. **NEW-2** — release text first-responder on Esc-commit so stray keystrokes /
   tool shortcuts don't edit the committed text.
3. **NEW-3** — confirm/clean up the stray first leg when leaving the angle tool
   mid-build.
4. **Human re-confirm BUG-2** and ⇧-marquee with a real keyboard (code already
   looks correct — this is verification, not a fix).

**Re-verify scorecard:** BUG-1 ✅ fixed · BUG-2 ✅ fixed-in-code (confirm by eye) ·
BUG-3 ✅ fixed · BUG-4 ✅ not reproduced · BUG-5 ✅ fixed.

_No code changes were made during QC._
