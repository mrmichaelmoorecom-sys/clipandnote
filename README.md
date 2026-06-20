[![License: CC BY-NC 4.0](https://img.shields.io/badge/License-CC%20BY--NC%204.0-blue.svg)](LICENSE)

# clipandnote

A fast, native macOS **screenshot markup** app — a modern, open (non-commercial)
take on Skitch. Capture from the menu bar, annotate with selectable objects,
keep a searchable history of every markup, and export real layered files.

Part of the **clip…** family alongside [clipandcue](https://clipandcue.com)
(clipboard history). The two are fully independent but interoperate: clipandnote
copies land as the *latest* clipboard item without flooding clipandcue's queue.

## Status

🚧 Early development (v0.1). Working today:

- Menu-bar status item with the full snapshot command set.
- Screen capture: Crosshair, Previous Area, Timed Crosshair, Fullscreen, Window, Menu.
- Captured image opens in a zoomable editor window.

## Design decisions

| Area | Decision |
|------|----------|
| Platform | macOS 14 Sonoma+, Mac-only (iOS companion later) |
| Stack | Swift + AppKit, SPM executable bundled into a `.app` (mirrors clipandcue) |
| AI | **100% on-device** — Vision for smart-select / subject-lift / OCR; on-device inpainting for erase |
| Sync | Own CloudKit container `iCloud.com.clipandnote.shared` (private DB) |
| clipandcue interop | Local pasteboard marker `com.clipandnote.markup` + `source` tag so markups don't fill clipandcue's history |
| License | CC BY-NC 4.0 — non-commercial use only |

## Roadmap

- **Phase 1 — Capture & shell** ✅ menu bar, capture engine, editor window
- **Phase 2 — Annotation canvas** — selectable/movable object model (arrow, box, ellipse, line, freehand, text, highlighter, blur/pixelate, crop) + **paste image as a new object** (the core Skitch fix)
- **Phase 3 — Document format** — open `.ctell` file (base image + vector objects + layers), real layered PDF/PNG/SVG export
- **Phase 4 — History & gallery** — local markup log, in-app scrollback gallery, last-10 in the menu bar (with tunable retention)
- **Phase 5 — CloudKit sync** + clipandcue interop (the pasteboard/queue handshake)
- **Phase 6 — On-device AI** — OCR-for-Claude optimization, smart select & outline, AI erase / modify / recolor
- **Phase 7 — iOS companion**

## Building

```sh
swift build
swift run        # launches the menu-bar app
```

A `.app` bundling + signing script (matching clipandcue's) lands with Phase 4.

## Snapshot naming (on-device)

Each capture is titled `<timestamp> · <label>`. The label is generated fully
on-device by combining three signals:

1. **OCR** of the most prominent text (Vision), refined with **Natural Language**
   so a heading/error/name is picked cleanly — used for text-heavy captures.
2. **Visual content classification** for image-heavy captures OCR can't describe.
   By default this uses Vision's built-in scene classifier; for screenshot-tuned
   labels ("Login screen", "Error dialog", "Code", "Chart"…) it uses a bundled
   **MobileCLIP** image encoder when present.

### Adding the MobileCLIP model (optional upgrade)

The CLIP path is dormant until you add the model — naming falls back to Vision +
OCR, so the app works without it. To enable it:

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install mobileclip coremltools torch
# download a checkpoint from https://github.com/apple/ml-mobileclip (e.g. mobileclip_s0.pt)
python scripts/export_mobileclip.py --checkpoint mobileclip_s0.pt --model mobileclip_s0
```

This writes `MobileCLIPImage.mlmodelc` + `clip_labels.json`. Place both in the
built app's `Contents/Resources/` (the only runtime cost is the image encoder + a
dot product — no text encoder, tokenizer, or network). Edit the `LABELS` list in
the script to tune the vocabulary.

## License

© 2026 Michael Moore. clipandnote is licensed under
[CC BY-NC 4.0](LICENSE). Free to use, modify, and share for **non-commercial**
purposes, with attribution. Commercial use is not permitted.
