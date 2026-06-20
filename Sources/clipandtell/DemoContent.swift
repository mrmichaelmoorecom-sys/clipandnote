import AppKit

/// Developer-only sample content used to exercise the editor without going
/// through screen capture (which needs a Screen Recording grant). Enabled by
/// running with the env var `CLIPANDTELL_DEMO=1`. Not used in normal operation.
enum DemoContent {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CLIPANDTELL_DEMO"] == "1"
    }

    static let canvasSize = CGSize(width: 1000, height: 640)

    /// A synthetic "screenshot" so markup (and pixelate redaction) has something
    /// realistic to sit on.
    static func makeBaseImage() -> NSImage {
        NSImage(size: canvasSize, flipped: true) { _ in
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: canvasSize).fill()

            // A "window" card.
            let card = NSBezierPath(roundedRect: NSRect(x: 60, y: 80, width: 880, height: 480),
                                    xRadius: 14, yRadius: 14)
            NSColor.white.setFill(); card.fill()
            NSColor(white: 0.8, alpha: 1).setStroke(); card.lineWidth = 1; card.stroke()

            // Title bar + traffic lights.
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: 84 + CGFloat(i) * 22, y: 98, width: 12, height: 12)).fill()
            }
            label("Account settings", at: CGPoint(x: 100, y: 130), size: 22, weight: .bold)
            label("Email     mike@example.com", at: CGPoint(x: 100, y: 180), size: 16)
            label("Password  hunter2-secret-pw", at: CGPoint(x: 100, y: 214), size: 16)
            label("Plan      Pro (renews monthly)", at: CGPoint(x: 100, y: 248), size: 16)

            // A button to point an arrow at.
            let btn = NSBezierPath(roundedRect: NSRect(x: 620, y: 180, width: 220, height: 120),
                                   xRadius: 10, yRadius: 10)
            NSColor.systemBlue.setFill(); btn.fill()
            label("Upgrade", at: CGPoint(x: 668, y: 224), size: 20, weight: .semibold, color: .white)

            for i in 0..<3 {
                NSColor(white: 0.88, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 100, y: 320 + CGFloat(i) * 40, width: 420, height: 18)).fill()
            }
            return true
        }
    }

    private static func label(_ s: String, at p: CGPoint, size: CGFloat,
                              weight: NSFont.Weight = .regular, color: NSColor = .black) {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]).draw(at: p)
    }

    /// One object of each kind, plus a pasted-image object, to verify rendering.
    static func makeObjects() -> [MarkupObject] {
        var objs: [MarkupObject] = []

        // Highlighter over the email line.
        var hi = MarkupObject(kind: .highlighter, frame: CGRect(x: 96, y: 176, width: 320, height: 24))
        hi.fill = .highlighter; objs.append(hi)

        // Pixelate redaction over the password.
        objs.append(MarkupObject(kind: .pixelate, frame: CGRect(x: 188, y: 208, width: 220, height: 26)))

        // Rectangle around the plan row.
        objs.append(MarkupObject(kind: .rectangle, frame: CGRect(x: 92, y: 240, width: 360, height: 30),
                                 stroke: .red, lineWidth: 3))

        // Ellipse + arrow pointing at the Upgrade button.
        objs.append(MarkupObject(kind: .ellipse, frame: CGRect(x: 612, y: 172, width: 236, height: 136),
                                 stroke: .red, lineWidth: 4))
        var arrow = MarkupObject(kind: .arrow, stroke: .red, lineWidth: 6)
        arrow.points = [CGPoint(x: 470, y: 430), CGPoint(x: 612, y: 250)]
        arrow.recomputeBounds(); objs.append(arrow)

        // Freehand squiggle.
        var pen = MarkupObject(kind: .freehand, stroke: RGBAColor(NSColor.systemBlue), lineWidth: 4)
        pen.points = (0...40).map { i in
            let x = 120 + CGFloat(i) * 6
            return CGPoint(x: x, y: 470 + sin(CGFloat(i) / 3) * 16)
        }
        pen.recomputeBounds(); objs.append(pen)

        // Text callout.
        var text = MarkupObject(kind: .text, frame: CGRect(x: 470, y: 470, width: 260, height: 40),
                                stroke: .red, text: "Click here to upgrade")
        text.fontSize = 26; objs.append(text)

        // A pasted-image object (proves paste-as-object lands as a movable layer).
        let swatch = NSImage(size: CGSize(width: 120, height: 90), flipped: true) { _ in
            NSColor.systemPurple.setFill(); NSRect(x: 0, y: 0, width: 120, height: 90).fill()
            DemoContent.label("pasted", at: CGPoint(x: 22, y: 34), size: 18, weight: .bold, color: .white)
            return true
        }
        if let png = swatch.pngData() {
            objs.append(MarkupObject(kind: .image, frame: CGRect(x: 740, y: 360, width: 120, height: 90),
                                     imageData: png))
        }
        return objs
    }

    static func makeDocument() -> MarkupDocument {
        MarkupDocument(baseImage: makeBaseImage(), objects: makeObjects(), canvasSize: canvasSize)
    }
}
