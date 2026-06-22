import AppKit

/// A momentary icon button (not NSButton — a borderless NSButton swallows clicks
/// in its blank area). Used for the layer up/down controls.
final class IconButton: NSView {
    var onClick: (() -> Void)?
    private let symbol: NSImage?
    private var pressed = false { didSet { needsDisplay = true } }

    // The window uses isMovableByWindowBackground for its unified toolbar look.
    // Without this override, a mouseDown on the button counts as "background"
    // and the window drags away under your cursor while you wait for a click.
    override var mouseDownCanMoveWindow: Bool { false }

    init(symbolName: String, tooltip: String) {
        self.symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        wantsLayer = true
        toolTip = tooltip
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        if pressed {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard let symbol else { return }
        let conf = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [.labelColor]))
        let img = symbol.withSymbolConfiguration(conf) ?? symbol
        let s = img.size
        img.draw(in: NSRect(x: (bounds.width - s.width) / 2,
                            y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// A single tool in the palette. A custom view (not NSButton) so it can support
/// press-and-hold (the text tool opens a font menu) and clean selected styling.
final class ToolButton: NSView {
    let tool: Tool
    var onClick: (() -> Void)?
    var onLongPress: (() -> Void)?     // nil = no long-press behavior

    var isSelected = false { didSet { needsDisplay = true } }

    // Without this the toolbar's window-movable-by-background takes over
    // during a long-press wait and the whole window slides under the cursor.
    override var mouseDownCanMoveWindow: Bool { false }

    /// When set, this closure produces the icon image (passed the current
    /// "selected" state so it can flip its tint). Replaces the SF Symbol path.
    var customRender: ((_ selected: Bool) -> NSImage?)? {
        didSet { needsDisplay = true }
    }

    /// Optional override for the arrow tool's fill (used by the toolbar to
    /// preview the active color). nil = default label tint.
    var fillProvider: (() -> NSColor)? {
        didSet { needsDisplay = true }
    }

    private let symbol: NSImage?
    private var longPressWork: DispatchWorkItem?
    private var longFired = false

    init(tool: Tool, symbolName: String, tooltip: String) {
        self.tool = tool
        self.symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 28))
        wantsLayer = true
        toolTip = tooltip
    }

    /// Force a re-draw (e.g. after the active color changes — colored tool
    /// icons re-render through their customRender closure on the next draw).
    func refreshIcon() { needsDisplay = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            // A neutral grey highlight that reads in both light + dark mode
            // (system fill colors automatically pick a tone with enough contrast
            // against the toolbar background).
            NSColor.tertiarySystemFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let tint = NSColor.labelColor

        // Custom SVG render takes precedence so the toolbar can show colored
        // previews that match the tool's actual output.
        if let make = customRender, let img = make(isSelected) {
            let s = img.size
            img.draw(in: NSRect(x: (bounds.width - s.width) / 2,
                                y: (bounds.height - s.height) / 2,
                                width: s.width, height: s.height))
            return
        }

        // The arrow tool previews the *actual* rendered arrow shape (tapered
        // shaft, swept-back head). Tip points upper-right; the toolbar feeds
        // the active color in so the icon matches what the tool draws.
        if tool == .arrow {
            let inset: CGFloat = 7
            let obj = MarkupObject(kind: .arrow,
                                   points: [CGPoint(x: inset, y: bounds.maxY - inset),
                                            CGPoint(x: bounds.maxX - inset, y: inset + 1)],
                                   lineWidth: 4.5)
            let pts = MarkupRenderer.arrowPolygon(obj)
            guard pts.count >= 3 else { return }
            let path = NSBezierPath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            path.close()
            path.lineJoinStyle = .round

            // Outline matches MarkupRenderer.contrastColor for the fill, so it
            // mirrors the contrasting edge the canvas paints around an arrow
            // marked in this color (dark fill → white outline, and vice versa).
            let fillColor = fillProvider?() ?? tint
            MarkupRenderer.contrastColor(for: fillColor).setStroke()
            path.lineWidth = 1.4
            path.stroke()
            fillColor.setFill()
            path.fill()
            return
        }

        guard let symbol else { return }
        let conf = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [tint]))
        let img = symbol.withSymbolConfiguration(conf) ?? symbol
        let s = img.size
        img.draw(in: NSRect(x: (bounds.width - s.width) / 2,
                            y: (bounds.height - s.height) / 2,
                            width: s.width, height: s.height))
    }

    override func mouseDown(with event: NSEvent) {
        longFired = false
        guard onLongPress != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.longFired = true
            self?.onLongPress?()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    override func mouseUp(with event: NSEvent) {
        longPressWork?.cancel(); longPressWork = nil
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if !longFired && inside { onClick?() }
    }
}
