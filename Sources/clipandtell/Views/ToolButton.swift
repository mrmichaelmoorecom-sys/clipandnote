import AppKit

/// A single tool in the palette. A custom view (not NSButton) so it can support
/// press-and-hold (the text tool opens a font menu) and clean selected styling.
final class ToolButton: NSView {
    let tool: Tool
    var onClick: (() -> Void)?
    var onLongPress: (() -> Void)?     // nil = no long-press behavior

    var isSelected = false { didSet { needsDisplay = true } }

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
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard let symbol else { return }
        let tint = isSelected ? NSColor.white : NSColor.labelColor
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
