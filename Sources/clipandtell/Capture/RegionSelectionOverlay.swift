import AppKit

/// A full-screen overlay for dragging out a capture region. Unlike
/// `screencapture -i` (which never reports the chosen rect), this hands back the
/// exact rectangle in screencapture's coordinate space (top-left origin, points)
/// — so "Previous Snapshot Area" can replay it. Returns nil if cancelled (Esc).
final class RegionSelectionOverlay: NSWindow {
    private static var active: RegionSelectionOverlay?

    private var completion: ((NSRect?) -> Void)?
    private let regionView = RegionSelectionView()
    private let screenHeight: CGFloat
    private let screenOrigin: NSPoint

    static func selectRegion(completion: @escaping (NSRect?) -> Void) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let overlay = RegionSelectionOverlay(screen: screen, completion: completion)
        active = overlay
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(screen: NSScreen, completion: @escaping (NSRect?) -> Void) {
        self.completion = completion
        self.screenHeight = screen.frame.height
        self.screenOrigin = screen.frame.origin
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        contentView = regionView
        regionView.onComplete = { [weak self] r in self?.finish(r) }
        regionView.onCancel = { [weak self] in self?.finish(nil) }
    }

    override var canBecomeKey: Bool { true }

    private func finish(_ viewRect: NSRect?) {
        orderOut(nil)
        var result: NSRect?
        if let r = viewRect, r.width >= 2, r.height >= 2 {
            // View coords (bottom-left) → screencapture top-left coords.
            result = NSRect(x: screenOrigin.x + r.minX,
                            y: screenHeight - r.maxY,
                            width: r.width, height: r.height)
        }
        let c = completion
        completion = nil
        Self.active = nil
        // Brief beat so the overlay is fully gone before the screenshot is taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { c?(result) }
    }
}

private final class RegionSelectionView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var rect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        guard rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.current?.cgContext.clear(rect)   // punch a clear hole

        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()

        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        label.draw(at: NSPoint(x: rect.minX, y: rect.maxY + 4), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        rect = .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = convert(event.locationInWindow, from: nil)
        rect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                      width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { onComplete?(rect) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }   // Esc
    }
}
