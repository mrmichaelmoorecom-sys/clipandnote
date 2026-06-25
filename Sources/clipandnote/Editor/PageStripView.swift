import AppKit

/// Vertical page navigator for a multi-page markup window: a left sidebar of
/// numbered page thumbnails. Click a tile to jump to that page; drag a tile to
/// reorder the pages. Lives as the `documentView` of a vertical scroll view
/// pinned to the window's left edge, shown only when the document has more than
/// one page.
final class PageStripView: NSView {
    /// Tapped a page (no drag) → jump to it.
    var onSelect: ((Int) -> Void)?
    /// Dragged page `from` to insertion slot `to` (0…count).
    var onReorder: ((Int, Int) -> Void)?

    /// Sidebar width (the scroll view's collapsed/expanded constraint target).
    static let barWidth: CGFloat = 96

    private var thumbs: [NSImage] = []
    private var current = 0

    private let tileW: CGFloat = 64
    private let tileImageH: CGFloat = 52
    private let numberH: CGFloat = 14
    private let vGap: CGFloat = 12
    private let vPad: CGFloat = 12
    private var tileH: CGFloat { tileImageH + numberH }

    // Drag tracking.
    private var pressIndex: Int?
    private var pressPoint: NSPoint = .zero
    private var dragPoint: NSPoint = .zero
    private var dragging = false

    // Flipped so page 1 sits at the top and y grows downward.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    // The window uses isMovableByWindowBackground, so AppKit would otherwise
    // treat a drag here as a window move (decided before mouseDown is even
    // dispatched). Opt out so our tile drag-to-reorder gets the events.
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(thumbs: [NSImage], current: Int) {
        self.thumbs = thumbs
        self.current = current
        let n = thumbs.count
        let height = vPad * 2 + CGFloat(max(n, 0)) * tileH + CGFloat(max(n - 1, 0)) * vGap
        frame = NSRect(x: 0, y: 0, width: Self.barWidth, height: max(height, 1))
        needsDisplay = true
    }

    // MARK: Layout helpers

    private func tileRect(_ i: Int) -> NSRect {
        let y = vPad + CGFloat(i) * (tileH + vGap)
        return NSRect(x: (bounds.width - tileW) / 2, y: y, width: tileW, height: tileH)
    }

    /// Thumbnail sits below the number within a tile.
    private func imageRect(in tile: NSRect) -> NSRect {
        NSRect(x: tile.minX, y: tile.minY + numberH, width: tile.width, height: tileImageH)
    }

    /// How many tile centers sit above `y` → the insertion slot for a drop.
    private func insertionIndex(forY y: CGFloat) -> Int {
        var idx = 0
        for i in thumbs.indices where tileRect(i).midY < y { idx = i + 1 }
        return idx
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for i in thumbs.indices {
            if dragging, pressIndex == i { continue }   // dragged tile drawn last, floating
            drawTile(i, at: tileRect(i))
        }
        guard dragging, let s = pressIndex else { return }
        // Insertion indicator (a horizontal bar) at the drop slot.
        let insert = insertionIndex(forY: dragPoint.y)
        let iy = vPad + CGFloat(insert) * (tileH + vGap) - vGap / 2
        NSColor.controlAccentColor.setFill()
        NSRect(x: (bounds.width - tileW) / 2, y: iy - 1, width: tileW, height: 2).fill()
        // The dragged tile follows the cursor.
        var t = tileRect(s)
        t.origin.y = dragPoint.y - tileH / 2
        drawTile(s, at: t)
    }

    private func drawTile(_ i: Int, at tile: NSRect) {
        let img = imageRect(in: tile)
        let isCur = (i == current)
        let box = NSBezierPath(roundedRect: img, xRadius: 5, yRadius: 5)
        (isCur ? NSColor.controlAccentColor.withAlphaComponent(0.18)
               : NSColor.windowBackgroundColor).setFill()
        box.fill()
        if i < thumbs.count {
            let fit = aspectFit(thumbs[i].size, in: img.insetBy(dx: 4, dy: 4))
            thumbs[i].draw(in: fit)
        }
        box.lineWidth = isCur ? 2 : 1
        (isCur ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: isCur ? .semibold : .regular),
            .foregroundColor: isCur ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ]
        let label = "\(i + 1)" as NSString
        let sz = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: tile.midX - sz.width / 2, y: tile.minY), withAttributes: attrs)
    }

    private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: Mouse — click to select, drag to reorder

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressPoint = p
        dragPoint = p
        pressIndex = thumbs.indices.first { tileRect($0).contains(p) }
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressIndex != nil else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(dragPoint.x - pressPoint.x, dragPoint.y - pressPoint.y) > 4 {
            dragging = true
        }
        if dragging {
            autoscroll(with: event)   // scroll the sidebar when dragging near its edges
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressIndex = nil; dragging = false; needsDisplay = true }
        guard let from = pressIndex else { return }
        if dragging {
            onReorder?(from, insertionIndex(forY: dragPoint.y))
        } else {
            onSelect?(from)
        }
    }
}
