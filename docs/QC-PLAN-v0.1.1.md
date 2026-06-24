# clipandnote — QC plan (v0.1.1 re-QC)

A re-QC of clipandnote's **editor window** after the v0.1.1 changes, intended to
be run by Claude Code (via the computer-use MCP) on a machine with the app built
locally. Drive the editor window — pick tools, draw, type, click,
screenshot-verify each result — and produce a written QC report. **No code
changes during QC** — report and triage only.

This builds on [`QC-PLAN.md`](QC-PLAN.md) (the full A–Q editor sweep) and the
first report [`QC-REPORT.md`](QC-REPORT.md). Run **Part 1** (regression smoke of
the original sweep), then **Part 2** (the new v0.1.1 features in detail), then
**Part 3** (re-verify the bugs the first pass found). Most of the *new* surface
is the **Select tool + toolbar**, so weight your time there.

## Ground rules

- **Report only.** Don't fix bugs in this pass; capture them for triage.
- **Non-destructive.** Scratch markups only. Never overwrite real `.can` files,
  never empty trash. Write all test exports/saves to `/tmp`. Cancel out of any
  "save over existing file" dialog.
- **Editor window only.** Two areas are intentionally **out of scope** because a
  computer-use agent can't visually verify them:
  - the **menu-bar status dropdown** — macOS excludes `NSPopover` overlay
    windows from agent screenshots (so the new capture-row icons can't be
    inspected — flag them under "needs your eyes");
  - the **screen-capture overlays** — crosshair / fullscreen / window grabs.
  Also out of scope: OCR accuracy on arbitrary content, CloudKit / clipandcue
  interop, and notarization / Gatekeeper (verify with `spctl -a -vv` instead).

## Setup

1. Confirm you're on v0.1.1:
   ```bash
   git -C <repo> log --oneline -1            # expect the v0.1.1 line or later
   /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" <repo>/Info.plist   # 0.1.1
   ```
2. Build a **debug** build (so a crash yields a console trace) and watch for
   compiler warnings — there should be **none** (see BUG-5):
   ```bash
   cd <repo>
   scripts/build_app.sh debug 2>&1 | tee /tmp/cn-build.log
   grep -i warning /tmp/cn-build.log || echo "no warnings ✓"
   ```
3. Launch from a terminal so stderr is captured:
   ```bash
   ./clipandnote.app/Contents/MacOS/clipandnote > /tmp/cn-qc.log 2>&1 &
   ```
4. `request_access` for **clipandnote** (full tier — native third-party app).
   - **Two-monitor note:** the editor window may open on a *secondary* display.
     If the first screenshot shows only the desktop, `open_application
     clipandnote` again and/or use `switch_display` to find the window.
   - **Refocus quirk (known, low-sev):** the *first* click right after the
     window gains focus is sometimes swallowed. If a click "does nothing,"
     just repeat it once.
5. Seed content:
   - **New Blank Clip** (empty-state button) → blank canvas for vector tools.
   - Open an existing screenshot PNG for tools needing a base image (crop,
     pixelate, OCR).
   - Copy an image to the clipboard, then ⌘V into a blank window to test paste.

For each case: run the action (prefer `computer_batch`), compare to the expected
result, screenshot, and record **PASS / FAIL / NEEDS-EYES**. On FAIL capture
exact repro steps and any `/tmp/cn-qc.log` output.

---

## Part 1 — Regression smoke (original A–Q)

Re-run the [`QC-PLAN.md`](QC-PLAN.md) matrix at a brisk pace — you're confirming
v0.1.1 didn't break v0.1.0, not re-deep-diving. Spend real time only on:

- **C. Draw tools** — every tool still draws in the active color; same-kind
  hover-grab still works.
- **G. Selection / move / resize** — single-select handles, marquee group,
  group move, endpoint reshape, click-outside-deselect. (Modifier-key selection
  is new — covered in Part 2.)
- **P. Export & `.can` round-trip** — PNG/PDF/SVG to `/tmp` + save/open a `.can`.
- **N. Undo / redo** — across tools, especially the new scale/duplicate ops.

Record one pass/fail line per area A–Q; only expand on regressions.

---

## Part 2 — New in v0.1.1 (focus area)

### R. Select-tool modifier keys
Seed: draw **5–6 distinct objects** (mix of shapes, a line/arrow, a text).
Switch to **Select (V)**.
- **Plain click** an object → selects **only** it (others deselect).
- **⇧-click** another object → **adds** it; keep ⇧-clicking to build a group.
  Each added object shows its dashed outline.
- **⇧-marquee** on empty canvas → **adds** every object the band touches to the
  existing selection (doesn't replace it).
- **⌘-click** a selected object → **removes just that one** from the group; the
  rest stay selected.
- **Plain click on empty canvas** → clears the selection.
- **⌘A** → selects **every** object **and** snaps the active tool to Select
  (try it while a *draw* tool is active — it should switch). In the **OCR**
  tool, ⌘A instead selects all recognized text regions.

### S. Scale a multi-selection (the size slider)
The toolbar **size slider** ("Stroke / text size", the thin→thick ramp) doubles
as a group-scale control **when 2+ objects are selected**.
- Select **2+ objects** (incl. at least one **text** and one **line/arrow**).
- Drag the **size slider** → the whole selection scales **in place** — each
  object about **its own center** (objects don't drift), and the scaling carries
  through **geometry, line weight, AND text font size**. Verify the text grows
  and line strokes thicken proportionally.
- Release and drag again → it scales further from the new size (slider re-parks
  mid-range each time).
- **One undo** (⌘Z) reverts the whole drag, not a dozen tiny steps.
- Scale a group up near the edge → the **canvas auto-grows** so nothing clips.
- **Single-selection check:** with exactly **one** object selected, the same
  slider still just sets its **stroke/text width** (no in-place scaling). Confirm
  the behavior only changes at 2+.

### T. Recolor a multi-selection (palette)
- Select **2+ objects**, click a **palette color** → **all** selected objects
  recolor at once (previously only a single object did).
- It **preserves each object's opacity** — recolor an object whose opacity you
  lowered and confirm it stays translucent (hue changes, alpha doesn't).
- A **filled** rectangle/ellipse in the selection keeps its **fill** in sync
  with the new stroke color.

### U. Duplicate — ⌘D (any tool)
- Select one object → **⌘D** → an offset copy (~18px down-right) appears and the
  **copy** becomes selected. The original is untouched.
- Select **several** → **⌘D** duplicates the whole set, offset, all copies
  selected.
- **Any-tool check:** with an object selected, switch to a **draw tool** (e.g.
  Rectangle) and press **⌘D** — it still duplicates the selection and **does not
  change the active tool**.
- ⌘D and the plain **D** key (double-arrow tool) must not collide.
- ⌘Z reverts a duplicate in one step.

### V. Copy / paste multiple objects
- Select **2+ objects** → **⌘C** → **⌘V** → **all** of them paste back as
  separate, movable objects, offset together, with the copies selected on the
  Select tool. (Both ⌘C and the toolbar **Copy** button take this path.)
- Single-object ⌘C/⌘V still works (offset duplicate).
- ⌘C with **nothing** selected → flattens the canvas to a PNG on the clipboard
  (paste into another app to confirm an image, not objects).

### W. Wordmark open-confirm (footer)
- Click the **"clipandnote" wordmark** in the editor footer (bottom-left).
- Expect a **confirmation sheet** — *"Open clipandnote.com?"* with **Open /
  Cancel** — **before** any browser launches.
- **Cancel** → nothing opens. **Open** → it opens clipandnote.com (you may let
  it open, or cancel to stay non-disruptive).

### X. Menu-bar capture icons — **NEEDS-EYES (out of agent scope)**
The menu-bar dropdown capture rows (Crosshair Clip, Previous Clip Area,
Fullscreen Clip, Window Clip, Menu Clip, New clipandnote) now each carry an SF
Symbol icon. The dropdown is an `NSPopover` and **can't be screenshotted** by the
agent — list this for the human to eyeball: each row should have a leading icon,
left-aligned, with the shortcut still on the right.

---

## Part 3 — Re-verify the first pass's bugs

From [`QC-REPORT.md`](QC-REPORT.md); all three had fixes land in v0.1.1.

- **BUG-2 (was: angle Shift-45° ignored on commit) — should be FIXED.**
  Ruler ▼ → **Angle**. Three-click an angle, **holding Shift** on the
  second/third clicks. The committed legs should **snap to 45°** (not the raw
  cursor angle). Test both the drag interaction and the three-click interaction.
- **BUG-1 (was: ruler label + arrowhead balloon at high width) — should be
  FIXED.** Ruler (M) → push the **width slider to max** → draw a ruler. The
  **"N px" label** should stay a sane size (no longer enormous / overlapping the
  ticks) and the **arrowhead** should not dwarf the spine. Check the angle **°**
  label at high width too.
- **BUG-5 (build warning) — should be FIXED.** Confirmed at Setup step 2 (no
  compiler warnings).
- **BUG-3 (wordmark one-click nav)** — addressed by the new confirm sheet
  (Part 2 / W).
- **BUG-4 (tool reverted to Text after Rect "Filled" popover)** — was not
  reproducible; the handler only flips fill state. Try a few times to confirm it
  stays gone, but don't block on it.

---

## Deliverable — QC report

Write the report to chat (and to `docs/QC-REPORT-v0.1.1.md`):

1. **Pass/fail table** — Part 1 areas A–Q (one line each) + Part 2 areas R–X.
2. **Each bug:** severity, repro steps, screenshot, console trace if it crashed.
3. **Re-verify results** for BUG-1/2/3/4/5 (fixed / still present / N/A).
4. **"Needs your eyes" checklist** — the menu-bar dropdown icons (X), the
   capture overlays, and any subtle rendering nits you flag but can't confirm.
5. **Prioritized bug list.**

No code changes — the human triages.
