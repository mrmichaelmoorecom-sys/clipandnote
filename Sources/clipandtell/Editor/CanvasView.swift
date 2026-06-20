import AppKit

/// The active drawing tool. `.select` manipulates existing objects; the rest
/// create new objects of the corresponding kind.
enum Tool: Equatable {
    case select, arrow, line, rectangle, ellipse, freehand, text, highlighter, pixelate

    var markupKind: MarkupKind? {
        switch self {
        case .select:      return nil
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
/// a clipandtell markup and keep it out of its history queue (interop, Phase 5).
extension NSPasteboard.PasteboardType {
    static let clipandtellMarkup = NSPasteboard.PasteboardType("com.clipandtell.markup")
}

/// The interactive markup canvas. Flipped (top-left origin) so coordinates match
/// the captured image and on-screen text. Draws the base image, every object,
/// and selection handles; routes mouse/keyboard into create / move / resize /
/// edit gestures; and supports undo, delete, paste-as-object, and copy-flattened.
final class CanvasView: NSView, NSTextFieldDelegate {

    var document: MarkupDocument { didSet { needsDisplay = true } }
    var tool: Tool = .select { didSet { if tool != .select { selectedID = nil; needsDisplay = true } } }
    var strokeColor: NSColor = RGBAColor.red.nsColor
    var lineWidth: CGFloat = 4

    private var selectedID: UUID?

    // Drag state
    private enum DragKind { case create, move, resize(Handle), endpoint(Int) }
    private var drag: DragKind?
    private var dragStart: CGPoint = .zero
    private var preDrag: MarkupObject?          // snapshot of the object being edited
    private var undoSnapshot: [MarkupObject]?   // objects array before the gesture

    // Inline text editing
    private var editingID: UUID?
    private var textField: NSTextField?

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

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        document.baseImage?.draw(in: bounds)

        for obj in document.objects where obj.id != editingID {
            MarkupRenderer.draw(obj, baseImage: document.baseImage)
        }
        if let sel = selectedObject { drawSelection(sel) }
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
        document.objects.reversed().first { $0.frame.insetBy(dx: -6, dy: -6).contains(p) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        let p = convert(event.locationInWindow, from: nil)
        undoSnapshot = document.objects

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

        // Creating a new object.
        guard let kind = tool.markupKind else { return }

        if kind == .text {
            var obj = MarkupObject(kind: .text,
                                   frame: CGRect(x: p.x, y: p.y, width: 200, height: 40),
                                   stroke: RGBAColor(strokeColor), lineWidth: lineWidth)
            obj.fontSize = max(lineWidth * 6, 22)
            document.objects.append(obj)
            selectedID = obj.id
            commitUndo()
            beginTextEditing(obj.id)
            return
        }

        var obj = MarkupObject(kind: kind,
                               stroke: RGBAColor(strokeColor),
                               lineWidth: lineWidth)
        if kind == .highlighter { obj.fill = .highlighter; obj.stroke = .highlighter }
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
        guard let drag, let id = selectedID, let idx = indexOf(id) else { return }
        let p = convert(event.locationInWindow, from: nil)

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
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; preDrag = nil }
        guard let id = selectedID, let idx = indexOf(id) else { return }

        // Discard degenerate just-created objects (an accidental click).
        if case .create = drag {
            let o = document.objects[idx]
            let tooSmall = !o.isPathBased && o.frame.width < 3 && o.frame.height < 3
            let noPath = o.isPathBased && (o.points.count < 2 ||
                hypot(o.points[0].x - o.points[1].x, o.points[0].y - o.points[1].y) < 3)
            if tooSmall || noPath {
                document.objects.remove(at: idx)
                selectedID = nil
                undoSnapshot = nil
                needsDisplay = true
                return
            }
            // Normalize negative-size frames from dragging up/left.
            document.objects[idx].frame = document.objects[idx].frame.standardized
        }
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
        switch event.keyCode {
        case 51, 117:   // delete / forward-delete
            deleteSelection()
        default:
            super.keyDown(with: event)
        }
    }

    private func deleteSelection() {
        guard let id = selectedID, let idx = indexOf(id) else { return }
        undoSnapshot = document.objects
        document.objects.remove(at: idx)
        selectedID = nil
        commitUndo()
        needsDisplay = true
    }

    // MARK: Standard edit actions (wired via the main Edit menu)

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        undoSnapshot = document.objects
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
            document.objects.append(obj)
            selectedID = obj.id
            tool = .select
            commitUndo()
            needsDisplay = true
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let png = flatten()?.pngData() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        pb.setData(Data(), forType: .clipandtellMarkup)   // interop marker
    }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    // MARK: Flatten

    /// Render base image + all objects (no selection chrome) to a single image.
    func flatten() -> NSImage? {
        let objs = document.objects
        let base = document.baseImage
        return NSImage(size: document.canvasSize, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: self.document.canvasSize).fill()
            base?.draw(in: NSRect(origin: .zero, size: self.document.canvasSize))
            for o in objs { MarkupRenderer.draw(o, baseImage: base) }
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
        let field = NSTextField(frame: obj.frame.insetBy(dx: -2, dy: -2))
        field.stringValue = obj.text
        field.font = NSFont.systemFont(ofSize: obj.fontSize, weight: .semibold)
        field.textColor = obj.stroke.nsColor
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.9)
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    private func commitTextEditing() {
        guard let id = editingID, let field = textField, let idx = indexOf(id) else { return }
        let value = field.stringValue
        field.removeFromSuperview()
        textField = nil
        editingID = nil

        if value.isEmpty {
            document.objects.remove(at: idx)   // empty text → discard
        } else {
            document.objects[idx].text = value
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: document.objects[idx].fontSize, weight: .semibold)
            ]
            let measured = (value as NSString).size(withAttributes: attrs)
            document.objects[idx].frame.size = CGSize(width: ceil(measured.width) + 8,
                                                      height: ceil(measured.height) + 4)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Undo

    private func commitUndo() {
        guard let previous = undoSnapshot, let um = undoManager else { undoSnapshot = nil; return }
        let current = document.objects
        um.registerUndo(withTarget: self) { target in
            target.undoSnapshot = current
            target.document.objects = previous
            target.selectedID = nil
            target.commitUndo()   // registers the inverse for redo
            target.needsDisplay = true
        }
        undoSnapshot = nil
    }
}
