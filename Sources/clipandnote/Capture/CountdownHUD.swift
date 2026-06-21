import AppKit

/// A brief, centered countdown shown before a delayed capture so you know
/// exactly when the shot fires (and have time to open the menu / set up the
/// screen). A non-activating, click-through panel: it never steals focus or
/// dismisses an open menu, and it removes itself before `completion` runs so it
/// never lands in the screenshot.
enum CountdownHUD {
    private static var panel: NSPanel?

    static func run(seconds: Int, completion: @escaping () -> Void) {
        panel?.orderOut(nil); panel = nil
        guard seconds > 0 else { completion(); return }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let side: CGFloat = 132
        let origin = NSPoint(x: screen.frame.midX - side / 2, y: screen.frame.midY - side / 2)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: side, height: side)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.hasShadow = false
        let view = CountdownView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        view.value = seconds
        p.contentView = view
        p.orderFrontRegardless()
        panel = p

        var remaining = seconds
        func tick() {
            remaining -= 1
            if remaining <= 0 {
                p.orderOut(nil)
                panel = nil
                // A beat so the HUD is fully gone before the capture is taken.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: completion)
            } else {
                view.value = remaining
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
    }
}

private final class CountdownView: NSView {
    var value: Int = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 26, yRadius: 26)
        NSColor.black.withAlphaComponent(0.72).setFill()
        disc.fill()
        let s = "\(value)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2),
               withAttributes: attrs)
    }
}
