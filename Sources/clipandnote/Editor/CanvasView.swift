import AppKit

/// The active drawing tool. `.select` manipulates existing objects; the rest
/// create new objects of the corresponding kind.
enum Tool: Equatable {
    case select, crop, arrow, line, rectangle, ellipse, freehand, text, highlighter, pixelate

    var markupKind: MarkupKind? {
        switch self {
        case .select, .crop: return nil
        case .arrow:       return .arrow
        case .line:        return .line
        case .rectangle:   return .rectangle
        case .ellipse:     return .ellipse
        case .freehand:    return .freehand
        case .text:        return .text
        case .highlighter: return .highlighter
        case .pixelate:    return .pixelate
        }
    }
}

/// Custom pasteboard type stamped on flattened copies so clipandcue can recognise
/// a clipandnote markup and keep it out of its history queue (interop, Phase 5).
extension NSPasteboard.PasteboardType {
    static let clipandnoteMarkup = NSPasteboard.PasteboardType("com.clipandnote.markup")
    /// A single copied markup object (JSON), so paste re-creates the object.
    static let clipandnoteObject = NSPasteboard.PasteboardType("com.clipandnote.object")
}

/// The interactive markup canvas. Flipped (top-left origin) so coordinates match
/// the captured image and on-screen text. Draws the base image, every object,
/// and selection handles; routes mouse/keyboard into create / move / resize /
/// edit gestures; and supports undo, delete, paste-as-object, and copy-flattened.
final class CanvasView: NSView, NSTextViewDelegate {

    var document: MarkupDocument { didSet { needsDisplay = true; onMutated?() } }
    /// Fired on any change to the document, so the editor can mark itself edited.
    var onMutated: (() -> Void)?
    var tool: Tool = .select { didSet { if tool != .select { selectedID = nil; needsDisplay = true } } }
    var strokeColor: NSColor = RGBAColor.red.nsColor
    var lineWidth: CGFloat = 4

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
        "v": .select, "c": .crop, "a": .arrow, "l": .line, "r": .rectangle, "o": .ellipse,
        "p": .freehand, "t": .text, "h": .highlighter, "x": .pixelate,
    ]

    func selectTool(_ t: Tool) { tool = t; onToolChanged?(t) }

    private var selectedID: UUID? { didSet { onSelectionChanged?(selectedObject) } }

    /// Translucent fill for a highlighter of the given color.
    static func highlighterFill(_ c: NSColor) -> RGBAColor {
        var x = RGBAColor(c); x.a = 0.38; return x
    }

    // Drag state
    private enum DragKind { case create, move, resize(Handle), endpoint(Int), crop }
    private var drag: DragKind?
    private var cropRect: CGRect = .zero

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
    }
    private var undoSnapshot: DocSnapshot?

    /// Fired when the canvas grows, so the editor can keep it centered.
    var onCanvasResized: (() -> Void)?

    private func snapshot() -> DocSnapshot {
        DocSnapshot(objects: document.objects, canvasSize: document.canvasSize,
                    baseImageFrame: document.baseImageFrame)
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
        let hit = hitTestObject(at: p)
        if tool == .select {
            (hit != nil ? NSCursor.openHand : NSCursor.arrow).set()
        } else if let k = tool.markupKind, hit?.kind == k {
            NSCursor.arrow.set()        // hovering same-kind object → will grab it
        } else {
            NSCursor.crosshair.set()    // will draw a new object
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        document.baseImage?.draw(in: document.baseImageFrame)

        for obj in document.objects where obj.id != editingID {
            MarkupRenderer.draw(obj, baseImage: document.baseImage, baseFrame: document.baseImageFrame)
        }
        if let sel = selectedObject { drawSelection(sel) }

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

        // Hairline border so the canvas reads as a distinct card against the
        // padded dark backdrop.
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func drawSelection(_ obj: MarkupObject) {
        let outline = NSBezierPath(rect: obj.frame.insetBy(dx: -2, dy: -2))
        outline.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()

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
            // Line/arrow expose two endpoint handles; freehand exposes none.
            guard obj.kind != .freehand, obj.points.count >= 2 else { return [:] }
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        let p = convert(event.locationInWindow, from: nil)
        undoSnapshot = snapshot()

        // Double-click a text object to edit it, regardless of the active tool.
        if event.clickCount == 2,
           let hit = hitTestObject(at: p), hit.kind == .text {
            selectedID = hit.id
            beginTextEditing(hit.id)
            return
        }

        if tool == .select {
            // 1. Handle drag on the current selection?
            if let sel = selectedObject {
                for (h, r) in handleRects(sel) where r.contains(p) {
                    preDrag = sel
                    if sel.isPathBased {
                        drag = .endpoint(h == .topLeft ? 0 : 1)
                    } else {
                        drag = .resize(h)
                    }
                    return
                }
            }
            // 2. Select / move an object, or deselect.
            if let hit = hitTestObject(at: p) {
                selectedID = hit.id
                preDrag = hit
                drag = .move
                dragStart = p
            } else {
                selectedID = nil
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

        // Creating a new object.
        guard let kind = tool.markupKind else { return }

        // If hovering over an existing object of the same kind, behave like the
        // select tool and grab it — don't stack a new one on top.
        if let hit = hitTestObject(at: p), hit.kind == kind {
            selectedID = hit.id
            preDrag = hit
            drag = .move
            dragStart = p
            needsDisplay = true
            return
        }

        if kind == .text {
            var obj = MarkupObject(kind: .text,
                                   frame: CGRect(x: p.x, y: p.y, width: 200, height: 40),
                                   stroke: RGBAColor(strokeColor), lineWidth: lineWidth)
            obj.fontSize = max(lineWidth * 6, 22)
            obj.fontName = fontName
            document.objects.append(obj)
            selectedID = obj.id
            commitUndo()
            beginTextEditing(obj.id)
            return
        }

        var obj = MarkupObject(kind: kind,
                               stroke: RGBAColor(strokeColor),
                               lineWidth: lineWidth)
        if kind == .highlighter {
            let f = Self.highlighterFill(strokeColor); obj.fill = f; obj.stroke = f
        }
        if kind == .pixelate { obj.fill = nil }
        if obj.isPathBased {
            obj.points = [p, p]
        } else {
            obj.frame = CGRect(origin: p, size: .zero)
        }
        document.objects.append(obj)
        selectedID = obj.id
        drag = .create
        dragStart = p
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .crop = drag {
            cropRect = rect(from: dragStart, to: p)
            needsDisplay = true
            return
        }
        guard let drag, let id = selectedID, let idx = indexOf(id) else { return }

        switch drag {
        case .create:
            if document.objects[idx].kind == .freehand {
                document.objects[idx].points.append(p)
                document.objects[idx].recomputeBounds()
            } else if document.objects[idx].isPathBased {
                document.objects[idx].points = [dragStart, p]
                document.objects[idx].recomputeBounds()
            } else {
                document.objects[idx].frame = rect(from: dragStart, to: p)
            }
        case .move:
            guard let pre = preDrag else { break }
            var moved = pre
            moved.move(by: CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y))
            document.objects[idx] = moved
        case .resize(let h):
            guard let pre = preDrag else { break }
            document.objects[idx].frame = resized(pre.frame, handle: h, to: p)
        case .endpoint(let i):
            guard let pre = preDrag, pre.points.count >= 2 else { break }
            var pts = pre.points
            pts[i] = p
            document.objects[idx].points = pts
            document.objects[idx].recomputeBounds()
        case .crop:
            break   // handled before the guard
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .crop = drag {
            drag = nil
            applyCrop(cropRect)
            cropRect = .zero
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
            } else if document.objects[idx].isPathBased {
                document.objects[idx].points = [dragStart, p]
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
            case .line, .arrow:
                degenerate = o.points.count < 2 ||
                    hypot(o.points[0].x - o.points[1].x, o.points[0].y - o.points[1].y) < 3
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
        case 51, 117:   // delete / forward-delete
            deleteSelection()
        default:
            super.keyDown(with: event)
        }
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
        guard let id = selectedID, let idx = indexOf(id) else { return }
        undoSnapshot = snapshot()
        document.objects.remove(at: idx)
        selectedID = nil
        commitUndo()
        needsDisplay = true
    }

    // MARK: Standard edit actions (wired via the main Edit menu)

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        undoSnapshot = snapshot()
        // A copied markup object → paste it as a new, offset object.
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
        if let img = NSImage(pasteboard: pb), let png = img.pngData() {
            // THE core Skitch fix: paste arrives as a new, movable object —
            // it never replaces the canvas or your existing markup.
            let size = fitted(img.size, into: document.canvasSize)
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
        let pb = NSPasteboard.general
        pb.clearContents()
        // An object is selected → copy just that object (paste re-creates it).
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

    // MARK: Active color / width (apply to selection + future objects)

    func setActiveColor(_ c: NSColor) {
        strokeColor = c
        // Live-update text that's currently being typed.
        if let id = editingID, let idx = indexOf(id) {
            document.objects[idx].stroke = RGBAColor(c)
            textView?.textColor = c
            return
        }
        guard let id = selectedID, let idx = indexOf(id) else { return }
        undoSnapshot = snapshot()
        if document.objects[idx].kind == .highlighter {
            document.objects[idx].fill = Self.highlighterFill(c)
            document.objects[idx].stroke = Self.highlighterFill(c)
        } else {
            document.objects[idx].stroke = RGBAColor(c)
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
        guard let id = selectedID, let idx = indexOf(id) else { return }
        undoSnapshot = snapshot()
        if document.objects[idx].kind == .text {
            document.objects[idx].fontSize = max(w * 5, 12)
            resizeTextFrame(idx)
        } else {
            document.objects[idx].lineWidth = w
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
        return NSImage(size: document.canvasSize, flipped: true) { _ in
            NSColor.white.setFill()
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
