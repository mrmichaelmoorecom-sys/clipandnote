import AppKit
import Vision

/// The active drawing tool. `.select` manipulates existing objects; the rest
/// create new objects of the corresponding kind.
enum Tool: Equatable {
    case select, ocr, crop, arrow, doubleArrow, line, rectangle, ellipse, freehand, text, highlighter, pixelate, ruler

    var markupKind: MarkupKind? {
        switch self {
        case .select, .crop, .ocr: return nil   // ocr extracts text, doesn't add a mark
        case .arrow:       return .arrow
        case .doubleArrow: return .doubleArrow
        case .line:        return .line
        case .rectangle:   return .rectangle
        case .ellipse:     return .ellipse
        case .freehand:    return .freehand
        case .text:        return .text
        case .highlighter: return .highlighter
        case .pixelate:    return .pixelate
        case .ruler:       return .ruler
        }
    }
}

/// Custom pasteboard type stamped on flattened copies so clipandcue can recognise
/// a clipandnote markup and keep it out of its history queue (interop, Phase 5).
extension NSPasteboard.PasteboardType {
    static let clipandnoteMarkup = NSPasteboard.PasteboardType("com.clipandnote.markup")
    /// A single copied markup object (JSON), so paste re-creates the object.
    static let clipandnoteObject = NSPasteboard.PasteboardType("com.clipandnote.object")
    /// Several copied objects (JSON array) from a marquee selection.
    static let clipandnoteObjects = NSPasteboard.PasteboardType("com.clipandnote.objects")
}

/// The interactive markup canvas. Flipped (top-left origin) so coordinates match
/// the captured image and on-screen text. Draws the base image, every object,
/// and selection handles; routes mouse/keyboard into create / move / resize /
/// edit gestures; and supports undo, delete, paste-as-object, and copy-flattened.
final class CanvasView: NSView, NSTextViewDelegate {

    var document: MarkupDocument { didSet { needsDisplay = true; onMutated?() } }
    /// Fired on any change to the document, so the editor can mark itself edited.
    var onMutated: (() -> Void)?
    var tool: Tool = .select {
        didSet {
            if tool != .select { selectedID = nil }
            if oldValue == .ruler && tool != .ruler { cancelAngleInProgress() }
            if tool == .ocr {
                ensureOCRRegions()      // scan the screenshot once on entry
            } else {
                ocrRegions = []         // free memory; clear visible boxes
                ocrSelected = []
                ocrBaseImageKey = nil
            }
            needsDisplay = true
        }
    }
    var strokeColor: NSColor = .black
    var lineWidth: CGFloat = 4
    /// Alpha multiplier applied to the strokeColor when creating any new
    /// non-highlighter mark. Tunable per-canvas via every drawing tool's
    /// ▼ slider so the user can dial in a translucent arrow / shape / text
    /// without changing the palette colour itself. Default 1.0 = fully opaque.
    var strokeOpacity: CGFloat = 1.0
    /// Highlighter's own translucency, tracked separately so picking the
    /// highlighter restores its Skitch-style 0.38 baseline instead of
    /// inheriting whatever opacity the user set for a different tool.
    var highlighterOpacity: CGFloat = 0.38

    /// Per-shape style toggles for newly-created objects. The user picks via
    /// the tool button's menu — existing marks aren't retroactively changed,
    /// only the next one drawn.
    var rectFilled: Bool = false
    var ellipseFilled: Bool = false

    /// The ruler tool draws either a dimension ruler or an angle, chosen from
    /// its ▼ dropdown.
    enum RulerMode { case ruler, angle }
    var rulerMode: RulerMode = .ruler {
        didSet { if rulerMode != oldValue { cancelAngleInProgress() } }
    }
    /// Angle-tool interaction supports two styles, unified in one state machine:
    ///   • Drag: press the vertex, drag out the first leg, release; move to
    ///     sweep the second leg; click to finalize.
    ///   • Click: click the vertex, click the first-leg end, click the
    ///     second-leg end (each click placed with a live preview on move).
    /// `pressed` is the brief ambiguous window between mouse-down and either a
    /// drag (→ first leg) or a release with no movement (→ click style).
    private enum AnglePhase { case idle, pressed, draggingFirstLeg, awaitingA, awaitingB }
    private var anglePhase: AnglePhase = .idle
    private var angleInProgressID: UUID?
    /// Document state from before the angle began, so finalize undoes the
    /// whole angle (not just the second leg).
    private var angleUndoSnapshot: DocSnapshot?

    /// Fired whenever the selection changes, so the toolbar can reflect the
    /// selected object's color and width.
    var onSelectionChanged: ((MarkupObject?) -> Void)?

    /// Fired when the tool changes from within the canvas (keyboard shortcut),
    /// so the toolbar can update its highlight.
    var onToolChanged: ((Tool) -> Void)?

    /// Active font family for new text objects; nil = default system font.
    var fontName: String?

    /// Single-key tool shortcuts.
    static let toolShortcuts: [String: Tool] = [
        "v": .select, "i": .ocr, "c": .crop, "a": .arrow, "d": .doubleArrow,
        "l": .line, "r": .rectangle, "o": .ellipse,
        "p": .freehand, "t": .text, "h": .highlighter, "x": .pixelate,
        "m": .ruler,
    ]

    func selectTool(_ t: Tool) { tool = t; onToolChanged?(t) }

    /// The full selection (one or many, via marquee). The source of truth.
    private var selectedIDs: Set<UUID> = [] {
        didSet {
            guard selectedIDs != oldValue else { return }
            onSelectionChanged?(selectedObject)
        }
    }
    /// Single-selection accessor used by inspectors, handles, layering and copy:
    /// reads as nil unless *exactly one* object is selected; assigning replaces
    /// the whole selection. Keeps the existing single-object call sites working.
    private var selectedID: UUID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }

    /// Translucent fill for a highlighter of the given color, at the canvas's
    /// current highlighter opacity (or an explicit override).
    static func highlighterFill(_ c: NSColor, opacity: CGFloat = 0.38) -> RGBAColor {
        var x = RGBAColor(c); x.a = opacity; return x
    }
    /// Convenience wrapper that uses this canvas's tunable opacity.
    func highlighterFill(_ c: NSColor) -> RGBAColor {
        Self.highlighterFill(c, opacity: highlighterOpacity)
    }

    // Drag state
    private enum DragKind { case create, move, resize(Handle), endpoint(Int), crop, marquee, ocr }
    private var drag: DragKind?
    /// In-progress marquee rectangle (select tool, dragging over empty canvas).
    private var marqueeRect: CGRect = .zero
    /// Pre-drag snapshot of every selected object, for moving a group together.
    private var preDragGroup: [UUID: MarkupObject] = [:]
    private var cropRect: CGRect = .zero
    /// In-progress OCR drag-select rectangle (text-grab tool).
    private var ocrRect: CGRect = .zero
    /// Briefly-shown HUD ("Copied 47 chars", etc.). Reset by hideOCRHud(_:).
    private var ocrHudMessage: String?
    private var ocrHudOk: Bool = true

    /// One recognised text region (Vision observation, projected to canvas
    /// coords). The grab-text tool surfaces these as Preview-style selectable
    /// boxes so the user can drag-highlight individual lines.
    private struct OCRRegion {
        let id = UUID()
        let bounds: CGRect    // canvas-space rectangle
        let text: String
    }
    private var ocrRegions: [OCRRegion] = []
    private var ocrSelected: Set<UUID> = []
    private var ocrBaseImageKey: ObjectIdentifier?    // re-OCR when the base image swaps

    /// Fired after a crop changes the canvas size (so the toolbar can refit).
    var onCropped: (() -> Void)?
    private var dragStart: CGPoint = .zero
    private var preDrag: MarkupObject?          // snapshot of the object being edited
    /// Full undoable state — objects plus canvas geometry, so canvas expansion
    /// undoes cleanly along with the edit that caused it.
    private struct DocSnapshot {
        var objects: [MarkupObject]
        var canvasSize: CGSize
        var baseImageFrame: CGRect
        var backgroundColor: RGBAColor
    }
    private var undoSnapshot: DocSnapshot?

    /// Fired when the canvas grows, so the editor can keep it centered.
    var onCanvasResized: (() -> Void)?

    private func snapshot() -> DocSnapshot {
        DocSnapshot(objects: document.objects, canvasSize: document.canvasSize,
                    baseImageFrame: document.baseImageFrame,
                    backgroundColor: document.backgroundColor)
    }

    // Inline text editing
    private var editingID: UUID?
    private var textView: NSTextView?

    /// Multi-line text measurement (honors embedded newlines).
    static func textSize(_ s: String, font: NSFont) -> NSSize {
        let bounds = (s as NSString).boundingRect(
            with: NSSize(width: 100_000, height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    init(document: MarkupDocument) {
        self.document = document
        super.init(frame: NSRect(origin: .zero, size: document.canvasSize))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // The window is movable-by-background (for the unified toolbar); never let a
    // canvas drag (marquee, drawing, moving objects) move the window instead.
    override var mouseDownCanMoveWindow: Bool { false }
    override func becomeFirstResponder() -> Bool { true }

    // MARK: Cursor feedback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Angle tool sweeping its second leg consumes the move.
        if angleMouseMoved(p) { return }
        // Grab-Text tool: I-beam over recognised text regions, otherwise
        // crosshair (you can still rubber-band-select multiple lines on
        // empty canvas between them).
        if tool == .ocr {
            if ocrRegions.contains(where: { $0.bounds.contains(p) }) {
                NSCursor.iBeam.set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }
        // Over a modify-handle on the current selection (any tool) → the
        // regular arrow cursor so the user knows the next click will tweak
        // the existing object rather than start a new one.
        if let sel = selectedObject,
           handleRects(sel).values.contains(where: { $0.contains(p) }) {
            NSCursor.arrow.set()
            return
        }
        let hit = hitTestObject(at: p)
        if tool == .select {
            NSCursor.arrow.set()        // plain system arrow (no openHand)
        } else if let k = tool.markupKind, hit?.kind == k {
            NSCursor.arrow.set()        // hovering same-kind object → will grab it
        } else {
            NSCursor.crosshair.set()    // will draw a new object
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        document.backgroundColor.nsColor.setFill()
        bounds.fill()
        document.baseImage?.draw(in: document.baseImageFrame)

        for obj in document.objects where obj.id != editingID {
            MarkupRenderer.draw(obj, baseImage: document.baseImage, baseFrame: document.baseImageFrame)
        }
        // Dashed outline on every selected object; resize handles only when a
        // single object is selected (a marquee group shows outlines, no handles).
        for obj in document.objects where selectedIDs.contains(obj.id) {
            drawSelectionOutline(obj)
        }
        if let sel = selectedObject { drawHandles(sel) }

        // Marquee rubber-band.
        if case .marquee = drag, marqueeRect.width > 0 || marqueeRect.height > 0 {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: marqueeRect).fill()
            NSColor.controlAccentColor.setStroke()
            let band = NSBezierPath(rect: marqueeRect)
            band.lineWidth = 1
            band.setLineDash([4, 3], count: 2, phase: 0)
            band.stroke()
        }

        // Crop preview: dim everything outside the crop rectangle.
        if case .crop = drag, cropRect.width > 0, cropRect.height > 0 {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: cropRect))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            dim.fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: cropRect); border.lineWidth = 1.5; border.stroke()
        }

        // Grab-Text overlay (Preview-style): each recognised line gets a
        // subtle outline so the user can see what's grabbable; selected ones
        // get a solid blue fill. The drag rect itself stays light so it
        // doesn't fight the selection highlights underneath.
        if tool == .ocr {
            for region in ocrRegions {
                let r = region.bounds.insetBy(dx: -1, dy: -1)
                if ocrSelected.contains(region.id) {
                    NSColor.systemBlue.withAlphaComponent(0.35).setFill()
                    NSBezierPath(rect: r).fill()
                } else {
                    NSColor.systemBlue.withAlphaComponent(0.45).setStroke()
                    let outline = NSBezierPath(rect: r)
                    outline.lineWidth = 1
                    outline.setLineDash([2, 2], count: 2, phase: 0)
                    outline.stroke()
                }
            }
            if case .ocr = drag, ocrRect.width > 0 || ocrRect.height > 0 {
                NSColor.systemBlue.withAlphaComponent(0.08).setFill()
                NSBezierPath(rect: ocrRect).fill()
                NSColor.systemBlue.withAlphaComponent(0.5).setStroke()
                let band = NSBezierPath(rect: ocrRect)
                band.lineWidth = 1
                band.setLineDash([4, 3], count: 2, phase: 0)
                band.stroke()
            }
        }

        // Brief "Copied N chars" / "No text found" HUD after an OCR grab.
        if let msg = ocrHudMessage {
            drawOCRHud(msg, ok: ocrHudOk)
        }

        // Hairline border so the canvas reads as a distinct card against the
        // padded dark backdrop.
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func drawSelectionOutline(_ obj: MarkupObject) {
        let outline = NSBezierPath(rect: obj.frame.insetBy(dx: -2, dy: -2))
        outline.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()
    }

    private func drawHandles(_ obj: MarkupObject) {
        NSColor.controlAccentColor.setFill()
        for r in handleRects(obj).values {
            let dot = NSBezierPath(ovalIn: r)
            NSColor.white.setFill(); dot.fill()
            NSColor.controlAccentColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
        }
    }

    // MARK: Geometry helpers

    private var selectedObject: MarkupObject? {
        guard let id = selectedID else { return nil }
        return document.objects.first { $0.id == id }
    }

    private func indexOf(_ id: UUID) -> Int? {
        document.objects.firstIndex { $0.id == id }
    }

    private static let handleSize: CGFloat = 11

    /// Resize/endpoint handle rects for the current selection.
    private func handleRects(_ obj: MarkupObject) -> [Handle: CGRect] {
        let s = Self.handleSize
        func r(_ c: CGPoint) -> CGRect { CGRect(x: c.x - s/2, y: c.y - s/2, width: s, height: s) }

        if obj.isPathBased {
            // Freehand exposes none. The curved double-arrow exposes 3 handles
            // (start, bezier control, end) so the user can shape the curve.
            // Line/arrow expose two endpoint handles.
            guard obj.kind != .freehand, obj.points.count >= 2 else { return [:] }
            if (obj.kind == .doubleArrow || obj.kind == .angle), obj.points.count >= 3 {
                return [.topLeft: r(obj.points[0]),
                        .top: r(obj.points[1]),
                        .bottomRight: r(obj.points[2])]
            }
            return [.topLeft: r(obj.points[0]), .bottomRight: r(obj.points[1])]
        }
        let f = obj.frame
        return [
            .topLeft: r(CGPoint(x: f.minX, y: f.minY)),
            .top: r(CGPoint(x: f.midX, y: f.minY)),
            .topRight: r(CGPoint(x: f.maxX, y: f.minY)),
            .right: r(CGPoint(x: f.maxX, y: f.midY)),
            .bottomRight: r(CGPoint(x: f.maxX, y: f.maxY)),
            .bottom: r(CGPoint(x: f.midX, y: f.maxY)),
            .bottomLeft: r(CGPoint(x: f.minX, y: f.maxY)),
            .left: r(CGPoint(x: f.minX, y: f.midY)),
        ]
    }

    private func hitTestObject(at p: CGPoint) -> MarkupObject? {
        // Use the standardized frame: a resize can leave a negative-size rect,
        // and CGRect.contains fails on those — which would make the object
        // unselectable after scaling.
        document.objects.reversed().first { $0.frame.standardized.insetBy(dx: -6, dy: -6).contains(p) }
    }

    // MARK: Mouse

    /// Start moving the current selection (one object or a marquee group).
    private func beginMove(at p: CGPoint) {
        preDragGroup = [:]
        for obj in document.objects where selectedIDs.contains(obj.id) {
            preDragGroup[obj.id] = obj
        }
        preDrag = selectedObject
        drag = .move
        dragStart = p
    }

    // MARK: Angle tool (drag, or three clicks — vertex, leg-1 end, leg-2 end)

    private func angleMouseDown(_ p: CGPoint) {
        switch anglePhase {
        case .idle:
            // Begin: vertex = p (points[1]). Drag-vs-click decided at mouse-up.
            angleUndoSnapshot = snapshot()
            var stroke = RGBAColor(strokeColor); stroke.a *= strokeOpacity
            var obj = MarkupObject(kind: .angle, stroke: stroke, lineWidth: lineWidth)
            obj.points = [p, p, p]   // [A, V, B]
            document.objects.append(obj)
            selectedID = obj.id
            angleInProgressID = obj.id
            anglePhase = .pressed
            dragStart = p            // vertex
            needsDisplay = true
        case .awaitingA:
            guard let idx = angleIdx() else { cancelAngleInProgress(); return }
            let vertexA = document.objects[idx].points[1]
            document.objects[idx].points[0] = NSEvent.modifierFlags.contains(.shift)
                ? Self.constrained45(p, from: vertexA) : p
            document.objects[idx].recomputeBounds()
            anglePhase = .awaitingB
            needsDisplay = true
        case .awaitingB:
            guard let id = angleInProgressID, let idx = angleIdx() else { cancelAngleInProgress(); return }
            let vertexB = document.objects[idx].points[1]
            document.objects[idx].points[2] = NSEvent.modifierFlags.contains(.shift)
                ? Self.constrained45(p, from: vertexB) : p
            document.objects[idx].recomputeBounds()
            finishAngle(id)
        case .pressed, .draggingFirstLeg:
            break   // mouse already down
        }
    }

    private func angleMouseDragged(_ p: CGPoint) {
        guard anglePhase == .pressed || anglePhase == .draggingFirstLeg,
              let idx = angleIdx() else { return }
        anglePhase = .draggingFirstLeg
        document.objects[idx].points[0] = NSEvent.modifierFlags.contains(.shift)
            ? Self.constrained45(p, from: dragStart) : p
        document.objects[idx].recomputeBounds()
        needsDisplay = true
    }

    private func angleMouseUp() {
        switch anglePhase {
        case .draggingFirstLeg:
            // Real drag → first leg placed, await the second. A tiny "drag"
            // (jitter) is treated as a click → await the first-leg end.
            if let idx = angleIdx() {
                let v = document.objects[idx].points[1], a = document.objects[idx].points[0]
                anglePhase = hypot(a.x - v.x, a.y - v.y) > 5 ? .awaitingB : .awaitingA
            } else { anglePhase = .awaitingA }
            needsDisplay = true
        case .pressed:
            anglePhase = .awaitingA   // plain click on the vertex
            needsDisplay = true
        default:
            break
        }
    }

    /// Live preview of the next point as the mouse moves between clicks.
    /// Returns true if consumed.
    private func angleMouseMoved(_ p: CGPoint) -> Bool {
        guard let idx = angleIdx() else { return false }
        let vertex = document.objects[idx].points[1]
        let q = NSEvent.modifierFlags.contains(.shift) ? Self.constrained45(p, from: vertex) : p
        switch anglePhase {
        case .awaitingA: document.objects[idx].points[0] = q
        case .awaitingB: document.objects[idx].points[2] = q
        default: return false
        }
        document.objects[idx].recomputeBounds()
        needsDisplay = true
        NSCursor.crosshair.set()
        return true
    }

    private func angleIdx() -> Int? { angleInProgressID.flatMap(indexOf) }

    private func finishAngle(_ id: UUID) {
        anglePhase = .idle
        angleInProgressID = nil
        selectedID = id
        undoSnapshot = angleUndoSnapshot   // undo removes the whole angle
        angleUndoSnapshot = nil
        commitUndo()
        needsDisplay = true
    }

    /// Drop an unfinished angle (tool switch, Esc, mode change).
    func cancelAngleInProgress() {
        defer { anglePhase = .idle; angleInProgressID = nil; angleUndoSnapshot = nil }
        guard let id = angleInProgressID, let idx = indexOf(id) else { return }
        document.objects.remove(at: idx)
        if selectedID == id { selectedID = nil }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        let p = convert(event.locationInWindow, from: nil)
        undoSnapshot = snapshot()

        // Angle tool (ruler tool, angle mode) — multi-stage interaction.
        if tool == .ruler, rulerMode == .angle {
            angleMouseDown(p); return
        }

        // Double-click a text object to edit it, regardless of the active tool.
        if event.clickCount == 2,
           let hit = hitTestObject(at: p), hit.kind == .text {
            selectedID = hit.id
            beginTextEditing(hit.id)
            return
        }

        // Handles on the current selection are reachable in *any* tool — so
        // you can tweak an existing object's endpoints / size without first
        // switching back to Select.
        if let sel = selectedObject {
            for (h, r) in handleRects(sel) where r.contains(p) {
                preDrag = sel
                if sel.isPathBased {
                    // handleRects emits the matching set per kind: doubleArrow
                    // gets 3 dots (topLeft / top / bottomRight); line + arrow
                    // get 2 (topLeft / bottomRight). Map accordingly so a
                    // 2-point object never resolves to an out-of-bounds index.
                    let idx: Int
                    if sel.kind == .doubleArrow || sel.kind == .angle {
                        idx = (h == .topLeft ? 0 : (h == .top ? 1 : 2))
                    } else {
                        idx = (h == .topLeft ? 0 : 1)
                    }
                    drag = .endpoint(idx)
                } else {
                    drag = .resize(h)
                }
                return
            }
        }

        if tool == .select {
            // Select / move an object, or start a marquee on empty canvas.
            if let hit = hitTestObject(at: p) {
                // Click inside the existing multi-selection → move the whole group.
                if !selectedIDs.contains(hit.id) {
                    selectedIDs = [hit.id]
                }
                beginMove(at: p)
            } else {
                selectedID = nil
                drag = .marquee
                dragStart = p
                marqueeRect = CGRect(origin: p, size: .zero)
            }
            needsDisplay = true
            return
        }

        if tool == .crop {
            drag = .crop
            dragStart = p
            cropRect = CGRect(origin: p, size: .zero)
            selectedID = nil
            needsDisplay = true
            return
        }

        if tool == .ocr {
            drag = .ocr
            dragStart = p
            ocrRect = CGRect(origin: p, size: .zero)
            selectedID = nil
            // Click on a recognised region selects just that one to start; an
            // empty-canvas click clears the previous selection.
            if let hit = ocrRegions.first(where: { $0.bounds.contains(p) }) {
                ocrSelected = [hit.id]
            } else {
                ocrSelected = []
            }
            needsDisplay = true
            return
        }

        // Creating a new object.
        guard let kind = tool.markupKind else { return }

        // If hovering over an existing object of the same kind, behave like the
        // select tool and grab it — don't stack a new one on top.
        if let hit = hitTestObject(at: p), hit.kind == kind {
            selectedID = hit.id
            beginMove(at: p)
            needsDisplay = true
            return
        }

        // Strokes for non-highlighter marks inherit canvas.strokeOpacity so
        // the per-tool ▼ slider can dial in a translucent shape / arrow /
        // text without changing the palette colour itself.
        var stroke = RGBAColor(strokeColor); stroke.a *= strokeOpacity

        if kind == .text {
            var obj = MarkupObject(kind: .text,
                                   frame: CGRect(x: p.x, y: p.y, width: 200, height: 40),
                                   stroke: stroke, lineWidth: lineWidth)
            obj.fontSize = max(lineWidth * 6, 22)
            obj.fontName = fontName
            document.objects.append(obj)
            selectedID = obj.id
            commitUndo()
            beginTextEditing(obj.id)
            return
        }

        var obj = MarkupObject(kind: kind,
                               stroke: stroke,
                               lineWidth: lineWidth)
        if kind == .highlighter {
            let f = highlighterFill(strokeColor); obj.fill = f; obj.stroke = f
        }
        if kind == .pixelate { obj.fill = nil }
        // Shape fill toggle (set via long-press on the tool button). Filled
        // shapes use the stroke colour as their fill.
        if kind == .rectangle, rectFilled { obj.fill = stroke }
        if kind == .ellipse,   ellipseFilled { obj.fill = stroke }
        if obj.isPathBased {
            if obj.kind == .doubleArrow {
                // Start, control (at start until drag computes a midpoint with
                // a default perpendicular bend), end. Drag tunes 1 & 2.
                obj.points = [p, p, p]
            } else {
                obj.points = [p, p]
            }
        } else {
            obj.frame = CGRect(origin: p, size: .zero)
        }
        document.objects.append(obj)
        selectedID = obj.id
        drag = .create
        dragStart = p
    }

    override func mouseDragged(with event: NSEvent) {
        if tool == .ruler, rulerMode == .angle {
            angleMouseDragged(convert(event.locationInWindow, from: nil)); return
        }
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)

        switch drag {
        case .crop:
            cropRect = rect(from: dragStart, to: p)
            needsDisplay = true
            return
        case .ocr:
            ocrRect = rect(from: dragStart, to: p)
            // Live-update the selection: every region touched by the rubber band.
            ocrSelected = Set(ocrRegions
                .filter { $0.bounds.intersects(ocrRect) }
                .map { $0.id })
            needsDisplay = true
            return
        case .marquee:
            marqueeRect = rect(from: dragStart, to: p)
            // Select every object the rubber-band touches (the base snapshot
            // isn't an object, so it's never caught — as required).
            selectedIDs = Set(document.objects
                .filter { $0.frame.standardized.intersects(marqueeRect) }
                .map { $0.id })
            needsDisplay = true
            return
        case .move:
            // Moves the whole selection (one object or a marquee group) together.
            let d = CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y)
            for (id, pre) in preDragGroup {
                guard let idx = indexOf(id) else { continue }
                var moved = pre
                moved.move(by: d)
                document.objects[idx] = moved
            }
            needsDisplay = true
            return
        case .create, .resize, .endpoint:
            break   // single-object edits, handled below
        }

        guard let id = selectedID, let idx = indexOf(id) else { return }
        switch drag {
        case .create:
            if document.objects[idx].kind == .freehand {
                document.objects[idx].points.append(p)
                document.objects[idx].recomputeBounds()
            } else if document.objects[idx].kind == .doubleArrow {
                let control = Self.defaultCurveControl(from: dragStart, to: p)
                document.objects[idx].points = [dragStart, control, p]
                document.objects[idx].recomputeBounds()
            } else if document.objects[idx].isPathBased {
                // Hold Shift to lock a straight path (ruler / line / arrow) to
                // the nearest 45° angle. Read the live modifier state (not the
                // event's) so it engages even if Shift is pressed mid-drag.
                let end = NSEvent.modifierFlags.contains(.shift)
                    ? Self.constrained45(p, from: dragStart) : p
                document.objects[idx].points = [dragStart, end]
                document.objects[idx].recomputeBounds()
            } else {
                document.objects[idx].frame = rect(from: dragStart, to: p)
            }
        case .resize(let h):
            guard let pre = preDrag else { break }
            document.objects[idx].frame = resized(pre.frame, handle: h, to: p)
        case .endpoint(let i):
            guard let pre = preDrag, pre.points.count >= 2 else { break }
            var pts = pre.points
            pts[i] = p
            document.objects[idx].points = pts
            document.objects[idx].recomputeBounds()
        case .move, .crop, .marquee, .ocr:
            break   // handled above
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .ruler, rulerMode == .angle {
            angleMouseUp(); return
        }
        if case .crop = drag {
            drag = nil
            applyCrop(cropRect)
            cropRect = .zero
            return
        }
        if case .ocr = drag {
            drag = nil
            ocrRect = .zero
            commitOCRSelection()
            needsDisplay = true
            return
        }
        if case .marquee = drag {
            drag = nil
            marqueeRect = .zero
            undoSnapshot = nil          // selection-only: not an undoable doc edit
            needsDisplay = true
            return
        }
        if case .move = drag {
            drag = nil; preDrag = nil; preDragGroup = [:]
            expandCanvasIfNeeded()      // grow if the move pushed past the snapshot
            commitUndo()
            needsDisplay = true
            return
        }
        defer { drag = nil; preDrag = nil }
        guard let id = selectedID, let idx = indexOf(id) else { return }

        // Discard degenerate just-created objects (an accidental click).
        if case .create = drag {
            // Re-apply geometry from the release point so a fast gesture whose
            // intermediate drag events were coalesced still yields the full shape.
            let p = convert(event.locationInWindow, from: nil)
            if document.objects[idx].kind == .freehand {
                document.objects[idx].points.append(p)
                document.objects[idx].recomputeBounds()
            } else if document.objects[idx].kind == .doubleArrow {
                let control = Self.defaultCurveControl(from: dragStart, to: p)
                document.objects[idx].points = [dragStart, control, p]
                document.objects[idx].recomputeBounds()
            } else if document.objects[idx].isPathBased {
                // Hold Shift to lock a straight path (ruler / line / arrow) to
                // the nearest 45° angle. Read the live modifier state (not the
                // event's) so it engages even if Shift is pressed mid-drag.
                let end = NSEvent.modifierFlags.contains(.shift)
                    ? Self.constrained45(p, from: dragStart) : p
                document.objects[idx].points = [dragStart, end]
                document.objects[idx].recomputeBounds()
            } else {
                document.objects[idx].frame = rect(from: dragStart, to: p)
            }
            let o = document.objects[idx]
            // Discard only genuine accidental clicks. Freehand is judged by point
            // count (its samples are always adjacent, so endpoint distance is a
            // false negative); other path kinds by endpoint distance.
            let degenerate: Bool
            switch o.kind {
            case .freehand: degenerate = o.points.count < 3
            case .line, .arrow, .ruler:
                degenerate = o.points.count < 2 ||
                    hypot(o.points[0].x - o.points[1].x, o.points[0].y - o.points[1].y) < 3
            case .doubleArrow:
                degenerate = o.points.count < 3 ||
                    hypot(o.points[0].x - o.points[2].x, o.points[0].y - o.points[2].y) < 3
            default:
                degenerate = o.frame.width < 3 && o.frame.height < 3
            }
            if degenerate {
                document.objects.remove(at: idx)
                selectedID = nil
                undoSnapshot = nil
                needsDisplay = true
                return
            }
            // Normalize negative-size frames from dragging up/left.
            document.objects[idx].frame = document.objects[idx].frame.standardized
        }
        // A resize can also leave a negative-size frame (dragging a handle past
        // the opposite edge) — standardize so the object stays selectable.
        if case .resize = drag {
            document.objects[idx].frame = document.objects[idx].frame.standardized
        }
        expandCanvasIfNeeded()   // grow if this edit pushed past the snapshot edges
        commitUndo()
        needsDisplay = true
    }

    /// Default quadratic-bezier control point for a brand-new doubleArrow:
    /// midpoint of (a, b), offset perpendicular by ~15 % of the length so the
    /// connector is visibly curved as soon as the user releases the drag.
    /// Snap `p` to the nearest 45° ray from `anchor`, keeping the cursor's
    /// distance — used for Shift-constrained straight paths.
    static func constrained45(_ p: CGPoint, from anchor: CGPoint) -> CGPoint {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        let dist = hypot(dx, dy)
        guard dist > 0.5 else { return p }
        let step = CGFloat.pi / 4
        let snapped = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: anchor.x + cos(snapped) * dist,
                       y: anchor.y + sin(snapped) * dist)
    }

    static func defaultCurveControl(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1 else { return CGPoint(x: mx, y: my) }
        // Perpendicular unit vector (bend always to one consistent side).
        let px = -dy / len, py = dx / len
        let bend = max(len * 0.15, 10)
        return CGPoint(x: mx + px * bend, y: my + py * bend)
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func resized(_ f: CGRect, handle h: Handle, to p: CGPoint) -> CGRect {
        var minX = f.minX, minY = f.minY, maxX = f.maxX, maxY = f.maxY
        switch h {
        case .topLeft:     minX = p.x; minY = p.y
        case .top:         minY = p.y
        case .topRight:    maxX = p.x; minY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom:      maxY = p.y
        case .bottomLeft:  minX = p.x; maxY = p.y
        case .left:        minX = p.x
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Single-key tool shortcuts — only when not editing text and no modifiers.
        if editingID == nil,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let ch = event.charactersIgnoringModifiers?.lowercased(),
           let t = Self.toolShortcuts[ch] {
            selectTool(t)
            return
        }
        switch event.keyCode {
        case 53:        // Esc — cancel an in-progress angle, else pass through
            if anglePhase != .idle { cancelAngleInProgress() } else { super.keyDown(with: event) }
        case 51, 117:   // delete / forward-delete
            deleteSelection()
        default:
            super.keyDown(with: event)
        }
    }

    /// Add `image` to the canvas as a new, movable image object — centered,
    /// scaled to fit, and selected. Used by paste and by the toolbar crosshair
    /// grab. Never replaces the base image or existing markup.
    func addImageObject(_ image: NSImage) {
        guard let png = image.pngData() else { return }
        let size = fitted(image.size, into: document.canvasSize)
        let origin = CGPoint(x: (document.canvasSize.width - size.width) / 2,
                             y: (document.canvasSize.height - size.height) / 2)
        let obj = MarkupObject(kind: .image,
                               frame: CGRect(origin: origin, size: size),
                               imageData: png)
        document.objects.append(obj)
        selectedID = obj.id
        tool = .select
        commitUndo()
        needsDisplay = true
    }

    /// Clear the current selection (single or multi) without changing the
    /// active tool — used when the user clicks the grey backdrop around the
    /// canvas to "drop" the selection so they can copy/share the whole
    /// markup, but still have the same tool active for the next stroke.
    /// Also finishes any in-progress text editing first, so clicking outside
    /// the canvas with the text tool commits the text (or discards it if
    /// empty) instead of leaving the editor stuck open.
    func deselectAll() {
        if editingID != nil { commitTextEditing() }
        guard !selectedIDs.isEmpty else { return }
        selectedIDs = []
        needsDisplay = true
    }

    // MARK: Z-order (layering)

    @objc func bringForward(_ sender: Any?) { moveSelected(by: +1) }
    @objc func sendBackward(_ sender: Any?) { moveSelected(by: -1) }
    @objc func bringToFront(_ sender: Any?) { moveSelectedToEdge(front: true) }
    @objc func sendToBack(_ sender: Any?) { moveSelectedToEdge(front: false) }

    private func moveSelected(by delta: Int) {
        guard let id = selectedID, let idx = indexOf(id) else { return }
        let target = idx + delta
        guard target >= 0, target < document.objects.count else { return }
        undoSnapshot = snapshot()
        document.objects.swapAt(idx, target)
        commitUndo(); needsDisplay = true
    }

    private func moveSelectedToEdge(front: Bool) {
        guard let id = selectedID, let idx = indexOf(id) else { return }
        undoSnapshot = snapshot()
        let obj = document.objects.remove(at: idx)
        if front { document.objects.append(obj) } else { document.objects.insert(obj, at: 0) }
        commitUndo(); needsDisplay = true
    }

    /// Apply a font family to the selected text object and to future text.
    func setActiveFont(_ family: String?) {
        fontName = family
        guard let id = selectedID, let idx = indexOf(id),
              document.objects[idx].kind == .text else { return }
        undoSnapshot = snapshot()
        document.objects[idx].fontName = family
        resizeTextFrame(idx)
        commitUndo(); needsDisplay = true
    }

    private func deleteSelection() {
        guard !selectedIDs.isEmpty else { return }
        undoSnapshot = snapshot()
        document.objects.removeAll { selectedIDs.contains($0.id) }
        selectedIDs = []
        commitUndo()
        needsDisplay = true
    }

    // MARK: Standard edit actions (wired via the main Edit menu)

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        undoSnapshot = snapshot()
        // Several copied objects (marquee selection) → paste them all, offset.
        if let data = pb.data(forType: .clipandnoteObjects),
           let originals = try? JSONDecoder().decode([MarkupObject].self, from: data),
           !originals.isEmpty {
            let copies = originals.map { $0.duplicated(offsetBy: CGSize(width: 18, height: 18)) }
            document.objects.append(contentsOf: copies)
            selectedIDs = Set(copies.map { $0.id })
            tool = .select
            expandCanvasIfNeeded()
            commitUndo()
            needsDisplay = true
            return
        }
        // A single copied markup object → paste it as a new, offset object.
        if let data = pb.data(forType: .clipandnoteObject),
           let original = try? JSONDecoder().decode(MarkupObject.self, from: data) {
            let obj = original.duplicated(offsetBy: CGSize(width: 18, height: 18))
            document.objects.append(obj)
            selectedID = obj.id
            tool = .select
            expandCanvasIfNeeded()
            commitUndo()
            needsDisplay = true
            return
        }
        if let img = NSImage(pasteboard: pb) {
            // THE core Skitch fix: paste arrives as a new, movable object —
            // it never replaces the canvas or your existing markup.
            addImageObject(img)
        } else if let str = pb.string(forType: .string), !str.isEmpty {
            var obj = MarkupObject(kind: .text,
                                   frame: CGRect(x: 40, y: 40, width: 300, height: 60),
                                   stroke: RGBAColor(strokeColor), text: str)
            obj.fontSize = 28
            obj.fontName = fontName
            document.objects.append(obj)
            selectedID = obj.id
            tool = .select
            commitUndo()
            needsDisplay = true
        }
    }

    @objc func copy(_ sender: Any?) {
        // In Grab-Text mode the highlighted regions ARE the selection — copy
        // them as plain text instead of duping any markup objects.
        if tool == .ocr, !ocrSelected.isEmpty {
            commitOCRSelection()
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        // A marquee group is selected → copy all of them (paste re-creates them).
        if selectedIDs.count > 1 {
            let objs = document.objects.filter { selectedIDs.contains($0.id) }
            if let data = try? JSONEncoder().encode(objs) {
                pb.setData(data, forType: .clipandnoteObjects)
                return
            }
        }
        // A single object is selected → copy just that object (paste re-creates it).
        if let id = selectedID, let obj = document.objects.first(where: { $0.id == id }),
           let data = try? JSONEncoder().encode(obj) {
            pb.setData(data, forType: .clipandnoteObject)
            return
        }
        // Nothing selected → copy the whole flattened markup.
        guard let png = flatten()?.pngData() else { return }
        pb.setData(png, forType: .png)
        pb.setData(Data(), forType: .clipandnoteMarkup)   // interop marker
    }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    /// Cmd+A in Grab-Text mode selects every recognised line.
    @objc override func selectAll(_ sender: Any?) {
        if tool == .ocr {
            ocrSelected = Set(ocrRegions.map { $0.id })
            needsDisplay = true
            return
        }
        // No general select-all elsewhere — leave the responder chain alone.
    }

    // MARK: Active color / width (apply to selection + future objects)

    func setActiveColor(_ c: NSColor) {
        strokeColor = c
        // Live-update text that's currently being typed.
        if let id = editingID, let idx = indexOf(id) {
            document.objects[idx].stroke = RGBAColor(c)
            textView?.textColor = c
            return
        }
        // Recolor every selected object (one or a whole shift/marquee group),
        // mirroring setActiveOpacity. Preserve each object's existing alpha so a
        // recolour changes hue without resetting opacity.
        guard !selectedIDs.isEmpty else { return }
        undoSnapshot = snapshot()
        for i in document.objects.indices where selectedIDs.contains(document.objects[i].id) {
            if document.objects[i].kind == .highlighter {
                var hf = RGBAColor(c); hf.a = document.objects[i].stroke.a
                document.objects[i].stroke = hf
                document.objects[i].fill = hf
            } else {
                var s = RGBAColor(c); s.a = document.objects[i].stroke.a
                document.objects[i].stroke = s
                if let f = document.objects[i].fill {   // filled shapes: fill follows stroke
                    var nf = RGBAColor(c); nf.a = f.a
                    document.objects[i].fill = nf
                }
            }
        }
        commitUndo()
        needsDisplay = true
    }

    /// Set the canvas background fill (shown wherever the canvas grew past the snapshot).
    func setBackgroundColor(_ c: NSColor) {
        let rgba = RGBAColor(c)
        guard rgba != document.backgroundColor else { return }
        undoSnapshot = snapshot()
        document.backgroundColor = rgba
        commitUndo()
        needsDisplay = true
    }

    /// Set the active tool's opacity. Mirrors setActiveWidth/setActiveColor:
    /// updates the canvas-wide default for the next mark, AND — if one or
    /// more objects are currently selected — pushes the change into each
    /// selected object's stroke (and fill for highlighter / filled shapes)
    /// so the slider reads as live editing of the whole selection.
    /// Highlighter has its own opacity backing; everything else uses
    /// strokeOpacity.
    func setActiveOpacity(_ a: CGFloat) {
        if tool == .highlighter { highlighterOpacity = a } else { strokeOpacity = a }
        guard !selectedIDs.isEmpty else { needsDisplay = true; return }
        undoSnapshot = snapshot()
        for i in document.objects.indices where selectedIDs.contains(document.objects[i].id) {
            if document.objects[i].kind == .highlighter {
                var c = document.objects[i].stroke; c.a = a
                document.objects[i].stroke = c
                document.objects[i].fill = c
            } else {
                var s = document.objects[i].stroke; s.a = a
                document.objects[i].stroke = s
                if var f = document.objects[i].fill {
                    f.a = a
                    document.objects[i].fill = f
                }
            }
        }
        commitUndo()
        needsDisplay = true
    }

    func setActiveWidth(_ w: CGFloat) {
        lineWidth = w
        // Live-update the size of text that's currently being typed.
        if let id = editingID, let idx = indexOf(id) {
            document.objects[idx].fontSize = max(w * 5, 12)
            textView?.font = document.objects[idx].resolvedFont()
            sizeTextView()
            return
        }
        guard !selectedIDs.isEmpty else { return }
        undoSnapshot = snapshot()
        for i in document.objects.indices where selectedIDs.contains(document.objects[i].id) {
            if document.objects[i].kind == .text {
                document.objects[i].fontSize = max(w * 5, 12)
                resizeTextFrame(i)
            } else {
                document.objects[i].lineWidth = w
            }
        }
        commitUndo()
        needsDisplay = true
    }

    private func resizeTextFrame(_ idx: Int) {
        let o = document.objects[idx]
        guard o.kind == .text, !o.text.isEmpty else { return }
        let size = (o.text as NSString).size(withAttributes: [.font: o.resolvedFont()])
        document.objects[idx].frame.size = CGSize(width: ceil(size.width) + 10,
                                                  height: ceil(size.height) + 6)
    }

    // MARK: Flatten

    /// Render base image + all objects (no selection chrome) to a single image.
    func flatten() -> NSImage? {
        let objs = document.objects
        let base = document.baseImage
        let baseFrame = document.baseImageFrame
        let bg = document.backgroundColor.nsColor
        return NSImage(size: document.canvasSize, flipped: true) { _ in
            bg.setFill()
            NSRect(origin: .zero, size: self.document.canvasSize).fill()
            base?.draw(in: baseFrame)
            for o in objs { MarkupRenderer.draw(o, baseImage: base, baseFrame: baseFrame) }
            return true
        }
    }

    private func fitted(_ size: CGSize, into bounds: CGSize) -> CGSize {
        let maxW = bounds.width * 0.8, maxH = bounds.height * 0.8
        let scale = min(1, min(maxW / max(size.width, 1), maxH / max(size.height, 1)))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    // MARK: Inline text editing

    private func beginTextEditing(_ id: UUID) {
        guard let obj = document.objects.first(where: { $0.id == id }) else { return }
        editingID = id
        // NSTextView gives multi-line editing — Return inserts a newline; commit
        // by clicking away or pressing Escape.
        let tv = NSTextView(frame: obj.frame.insetBy(dx: -3, dy: -3))
        tv.string = obj.text
        tv.font = obj.resolvedFont()
        tv.textColor = obj.stroke.nsColor
        tv.isRichText = false
        // System text assistance: live spell-check with red underlines,
        // autocorrect suggestions, and the inline completion list (Esc to
        // summon). Matches typing in any native macOS text field.
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.isAutomaticTextReplacementEnabled = true
        tv.isGrammarCheckingEnabled = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: 100_000, height: 100_000)
        tv.textContainerInset = NSSize(width: 3, height: 3)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.white.withAlphaComponent(0.92)
        tv.wantsLayer = true
        tv.layer?.cornerRadius = 3
        tv.delegate = self
        addSubview(tv)
        textView = tv
        sizeTextView()
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    private func sizeTextView() {
        guard let tv = textView, let obj = editingID.flatMap({ id in
            document.objects.first { $0.id == id } }) else { return }
        let measured = Self.textSize(tv.string.isEmpty ? " " : tv.string, font: obj.resolvedFont())
        tv.frame.size = CGSize(width: max(measured.width, 40) + 14, height: measured.height + 10)
    }

    func textDidChange(_ notification: Notification) { sizeTextView() }

    /// Escape commits the edit (Return is left to insert a newline).
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    private func commitTextEditing() {
        guard let id = editingID, let tv = textView, let idx = indexOf(id) else { return }
        let value = tv.string
        tv.removeFromSuperview()
        textView = nil
        editingID = nil

        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.objects.remove(at: idx)   // empty text → discard
        } else {
            document.objects[idx].text = value
            let measured = Self.textSize(value, font: document.objects[idx].resolvedFont())
            document.objects[idx].frame.size = CGSize(width: measured.width + 10,
                                                      height: measured.height + 6)
            expandCanvasIfNeeded()
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Undo

    private func commitUndo() {
        guard let previous = undoSnapshot, let um = undoManager else { undoSnapshot = nil; return }
        let current = snapshot()
        um.registerUndo(withTarget: self) { target in
            target.undoSnapshot = current
            target.applySnapshot(previous)
            target.commitUndo()   // registers the inverse for redo
        }
        undoSnapshot = nil
    }

    private func applySnapshot(_ s: DocSnapshot) {
        document.objects = s.objects
        document.canvasSize = s.canvasSize
        document.baseImageFrame = s.baseImageFrame
        document.backgroundColor = s.backgroundColor
        selectedID = nil
        setFrameSize(s.canvasSize)
        onCanvasResized?()
        needsDisplay = true
    }

    // MARK: Auto-expand

    /// When an object moves past the snapshot edges, grow the canvas to fit it
    /// (with a margin) and re-center the content so nothing is clipped.
    func expandCanvasIfNeeded() {
        var union = document.baseImageFrame
        for o in document.objects {
            union = union.union(o.frame.standardized)
            for p in o.points { union = union.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        }
        let fits = union.minX >= 0 && union.minY >= 0
            && union.maxX <= document.canvasSize.width
            && union.maxY <= document.canvasSize.height
        guard !fits else { return }

        let m: CGFloat = 24
        let newSize = CGSize(width: union.width + m * 2, height: union.height + m * 2)
        let offset = CGSize(width: m - union.minX, height: m - union.minY)
        document.baseImageFrame = document.baseImageFrame.offsetBy(dx: offset.width, dy: offset.height)
        for i in document.objects.indices { document.objects[i].move(by: offset) }
        document.canvasSize = newSize
        setFrameSize(newSize)
        onCanvasResized?()
        needsDisplay = true
    }

    /// Crop the canvas to `rect` (canvas coords): shift the base image + objects,
    /// drop objects that fall entirely outside, and resize the canvas.
    // MARK: OCR (Grab Text — Preview-style text selection)

    /// Scan the entire base image once when the OCR tool is selected, so the
    /// user can drag through the recognised text regions instead of having to
    /// draw a precise rectangle. Skips if we already have regions for this base
    /// image. Vision request happens off the main thread; results land on main.
    private func ensureOCRRegions() {
        guard let base = document.baseImage,
              let baseCG = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showOCRHud("No screenshot to read.", ok: false); return
        }
        let key = ObjectIdentifier(base)
        if key == ocrBaseImageKey, !ocrRegions.isEmpty { return }
        ocrBaseImageKey = key
        ocrRegions = []
        ocrSelected = []
        let baseFrame = document.baseImageFrame
        let imgW = base.size.width, imgH = base.size.height

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: baseCG, options: [:]).perform([request])

            let observations = (request.results ?? [])
                .compactMap { (o: VNRecognizedTextObservation) -> OCRRegion? in
                    guard let cand = o.topCandidates(1).first, cand.confidence > 0.3 else { return nil }
                    let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    // Vision's boundingBox is normalised, bottom-left origin.
                    // Flip Y and scale to image pixels, then map to canvas coords
                    // via the base-image frame.
                    let nb = o.boundingBox
                    let px = nb.minX * imgW
                    let py = (1 - nb.maxY) * imgH
                    let pw = nb.width * imgW
                    let ph = nb.height * imgH
                    let scaleX = baseFrame.width  / max(1, imgW)
                    let scaleY = baseFrame.height / max(1, imgH)
                    let canvas = CGRect(x: baseFrame.minX + px * scaleX,
                                        y: baseFrame.minY + py * scaleY,
                                        width:  pw * scaleX,
                                        height: ph * scaleY)
                    return OCRRegion(bounds: canvas, text: text)
                }

            DispatchQueue.main.async {
                guard let self, self.tool == .ocr else { return }
                self.ocrRegions = observations
                if observations.isEmpty { self.showOCRHud("No text found.", ok: false) }
                self.needsDisplay = true
            }
        }
    }

    /// Compute the current text selection in reading order (top → bottom,
    /// left → right) so paste reads naturally.
    private func ocrSelectionText() -> String {
        let chosen = ocrRegions.filter { ocrSelected.contains($0.id) }
            .sorted { a, b in
                // Group by line (within a small Y tolerance), then sort by X.
                let lineEps: CGFloat = max(a.bounds.height, b.bounds.height) * 0.4
                if abs(a.bounds.minY - b.bounds.minY) > lineEps {
                    return a.bounds.minY < b.bounds.minY
                }
                return a.bounds.minX < b.bounds.minX
            }
        return chosen.map { $0.text }.joined(separator: "\n")
    }

    /// Copy whatever's currently selected (called on mouseUp) and HUD-confirm.
    private func commitOCRSelection() {
        let text = ocrSelectionText()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showOCRHud("Copied \(text.count) char\(text.count == 1 ? "" : "s")", ok: true)
    }

    /// Show the OCR HUD label and auto-hide it after 1.6 s.
    private func showOCRHud(_ message: String, ok: Bool) {
        ocrHudMessage = message
        ocrHudOk = ok
        needsDisplay = true
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideOCRHud),
                                               object: nil)
        perform(#selector(hideOCRHud), with: nil, afterDelay: 1.6)
    }

    @objc private func hideOCRHud() {
        ocrHudMessage = nil
        needsDisplay = true
    }

    /// A rounded chip at the top-centre of the canvas showing the OCR result.
    private func drawOCRHud(_ message: String, ok: Bool) {
        let pad: CGFloat = 10
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let textSize = (message as NSString).size(withAttributes: attrs)
        let chipSize = NSSize(width: textSize.width + pad * 2, height: textSize.height + 8)
        let chip = NSRect(x: (bounds.width - chipSize.width) / 2,
                          y: 16,                                // 16pt from top in flipped coords
                          width: chipSize.width, height: chipSize.height)
        let bg = (ok ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.92)
        bg.setFill()
        NSBezierPath(roundedRect: chip, xRadius: chipSize.height / 2,
                     yRadius: chipSize.height / 2).fill()
        (message as NSString).draw(at: NSPoint(x: chip.minX + pad, y: chip.minY + 4),
                                    withAttributes: attrs)
    }

    private func applyCrop(_ rect: CGRect) {
        let crop = rect.standardized
        guard crop.width >= 8, crop.height >= 8 else { needsDisplay = true; return }
        undoSnapshot = snapshot()
        let offset = CGSize(width: -crop.minX, height: -crop.minY)
        document.baseImageFrame = document.baseImageFrame.offsetBy(dx: offset.width, dy: offset.height)
        let newBounds = CGRect(origin: .zero, size: crop.size)
        var kept: [MarkupObject] = []
        for var obj in document.objects {
            obj.move(by: offset)
            if obj.frame.standardized.intersects(newBounds) { kept.append(obj) }
        }
        document.objects = kept
        document.canvasSize = crop.size
        selectedID = nil
        setFrameSize(crop.size)
        commitUndo()
        selectTool(.select)
        onCropped?()
        needsDisplay = true
    }
}
