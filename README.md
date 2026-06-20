[![License: CC BY-NC 4.0](https://img.shields.io/badge/License-CC%20BY--NC%204.0-blue.svg)](LICENSE)

# clipandtell

A fast, native macOS **screenshot markup** app — a modern, open (non-commercial)
take on Skitch. Capture from the menu bar, annotate with selectable objects,
keep a searchable history of every markup, and export real layered files.

Part of the **clip…** family alongside [clipandcue](https://clipandcue.com)
(clipboard history). The two are fully independent but interoperate: clipandtell
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
| Sync | Own CloudKit container `iCloud.com.clipandtell.shared` (private DB) |
| clipandcue interop | Local pasteboard marker `com.clipandtell.markup` + `source` tag so markups don't fill clipandcue's history |
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

## License

© 2026 Michael Moore. clipandtell is licensed under
[CC BY-NC 4.0](LICENSE). Free to use, modify, and share for **non-commercial**
purposes, with attribution. Commercial use is not permitted.
