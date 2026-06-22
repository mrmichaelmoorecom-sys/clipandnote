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
/// a split menu (tap the icon = select tool, tap the small ▼ at the bottom =
/// open a tool-specific menu) and clean selected styling.
final class ToolButton: NSView {
    let tool: Tool
    var onClick: (() -> Void)?
    /// Set on tools with a fill/outline (or font) menu; tapping the small ▼
    /// at the bottom of the button invokes it. Existence of this closure also
    /// draws the indicator triangle.
    var onShowMenu: (() -> Void)?

    var isSelected = false { didSet { needsDisplay = true } }

    // Without this the toolbar's window-movable-by-background takes over and
    // the whole window slides under the cursor while you're clicking buttons.
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
    private var hasMenu: Bool { onShowMenu != nil }
    /// Hit area for the ▼ indicator — bottom-center, slightly wider than the
    /// visible triangle so it's easy to tap. Anywhere else inside `bounds`
    /// counts as the main icon tap.
    private var menuTapRect: NSRect {
        NSRect(x: bounds.midX - 7, y: 0, width: 14, height: 8)
    }

    init(tool: Tool, symbolName: String, tooltip: String) {
        self.tool = tool
        self.symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        toolTip = tooltip
    }

    /// Force a re-draw (e.g. after the active color changes — colored tool
    /// icons re-render through their customRender closure on the next draw).
    func refreshIcon() { needsDisplay = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }

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

        if let symbol {
            let conf = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(paletteColors: [tint]))
            let img = symbol.withSymbolConfiguration(conf) ?? symbol
            let s = img.size
            // Shift the icon up by half the indicator's height so it stays
            // visually centred above the ▼.
            let yOffset: CGFloat = hasMenu ? 3 : 0
            img.draw(in: NSRect(x: (bounds.width - s.width) / 2,
                                y: (bounds.height - s.height) / 2 + yOffset,
                                width: s.width, height: s.height))
        }

        // The ▼ indicator at the bottom-center of the button when this tool
        // has a menu (rectangle, ellipse, text). Click it to open the menu.
        if hasMenu {
            drawMenuIndicator()
        }
    }

    /// Small downward triangle centred at the bottom of the button.
    private func drawMenuIndicator() {
        let cx = bounds.midX
        let halfW: CGFloat = 3
        let h: CGFloat = 3
        let topY: CGFloat = 5
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: cx - halfW, y: topY))
        tri.line(to: NSPoint(x: cx + halfW, y: topY))
        tri.line(to: NSPoint(x: cx,         y: topY - h))
        tri.close()
        NSColor.secondaryLabelColor.setFill()
        tri.fill()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if hasMenu && menuTapRect.contains(p) {
            onShowMenu?()
        } else {
            onClick?()
        }
    }
}
