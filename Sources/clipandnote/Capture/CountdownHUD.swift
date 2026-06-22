import AppKit

/// A brief, centered countdown shown before a delayed capture so you know
/// exactly when the shot fires (and have time to open the menu / set up the
/// screen). A non-activating, click-through panel: it never steals focus or
/// dismisses an open menu, and it removes itself before `completion` runs so it
/// never lands in the screenshot.
enum CountdownHUD {
    private static var panel: NSPanel?

    static func run(seconds: Int, hint: String? = nil, completion: @escaping () -> Void) {
        panel?.orderOut(nil); panel = nil
        guard seconds > 0 else { completion(); return }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let w: CGFloat = 240, h: CGFloat = 156
        let origin = NSPoint(x: screen.frame.midX - w / 2, y: screen.frame.midY - h / 2)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.hasShadow = false
        let view = CountdownView(frame: NSRect(origin: .zero, size: NSSize(width: w, height: h)))
        view.hint = hint
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
    var hint: String?

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 22, yRadius: 22)
        NSColor.black.withAlphaComponent(0.74).setFill()
        card.fill()

        let hasHint = !(hint?.isEmpty ?? true)
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 60, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let num = "\(value)" as NSString
        let numSize = num.size(withAttributes: numAttrs)
        let numY = hasHint ? bounds.midY - numSize.height / 2 + 16 : bounds.midY - numSize.height / 2
        num.draw(at: NSPoint(x: bounds.midX - numSize.width / 2, y: numY), withAttributes: numAttrs)

        if let hint, hasHint {
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                .paragraphStyle: para,
            ]
            let rect = NSRect(x: 14, y: 22, width: bounds.width - 28, height: 20)
            (hint as NSString).draw(in: rect, withAttributes: hintAttrs)
        }
    }
}
