import AppKit

/// Draws markup objects using AppKit primitives into the *current* graphics
/// context, assuming a flipped (top-left origin) coordinate space — which matches
/// both the on-screen `CanvasView` and the offscreen export context (Phase 3).
/// Keeping all drawing here means the editor and the exporter render identically.
enum MarkupRenderer {

    static func draw(_ obj: MarkupObject, baseImage: NSImage?) {
        switch obj.kind {
        case .rectangle:   drawRect(obj)
        case .ellipse:     drawEllipse(obj)
        case .line:        drawLine(obj)
        case .arrow:       drawArrow(obj)
        case .freehand:    drawFreehand(obj)
        case .highlighter: drawHighlighter(obj)
        case .text:        drawText(obj)
        case .image:       drawImage(obj)
        case .pixelate:    drawPixelate(obj, baseImage: baseImage)
        }
    }

    // MARK: Shapes

    private static func drawRect(_ o: MarkupObject) {
        let p = NSBezierPath(rect: o.frame)
        p.lineWidth = o.lineWidth
        if let fill = o.fill { fill.nsColor.setFill(); p.fill() }
        o.stroke.nsColor.setStroke(); p.stroke()
    }

    private static func drawEllipse(_ o: MarkupObject) {
        let p = NSBezierPath(ovalIn: o.frame)
        p.lineWidth = o.lineWidth
        if let fill = o.fill { fill.nsColor.setFill(); p.fill() }
        o.stroke.nsColor.setStroke(); p.stroke()
    }

    private static func drawLine(_ o: MarkupObject) {
        guard o.points.count >= 2 else { return }
        let p = NSBezierPath()
        p.move(to: o.points[0]); p.line(to: o.points[1])
        p.lineWidth = o.lineWidth; p.lineCapStyle = .round
        o.stroke.nsColor.setStroke(); p.stroke()
    }

    private static func drawArrow(_ o: MarkupObject) {
        guard o.points.count >= 2 else { return }
        let start = o.points[0], end = o.points[1]
        let shaft = NSBezierPath()
        shaft.move(to: start); shaft.line(to: end)
        shaft.lineWidth = o.lineWidth; shaft.lineCapStyle = .round
        o.stroke.nsColor.setStroke(); shaft.stroke()

        // Arrowhead — scales with line width.
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = max(o.lineWidth * 3.2, 12)
        let spread = CGFloat.pi / 7
        let h1 = CGPoint(x: end.x - headLen * cos(angle - spread),
                         y: end.y - headLen * sin(angle - spread))
        let h2 = CGPoint(x: end.x - headLen * cos(angle + spread),
                         y: end.y - headLen * sin(angle + spread))
        let head = NSBezierPath()
        head.move(to: end); head.line(to: h1); head.line(to: h2); head.close()
        o.stroke.nsColor.setFill(); head.fill()
    }

    private static func drawFreehand(_ o: MarkupObject) {
        guard o.points.count >= 2 else { return }
        let p = NSBezierPath()
        p.move(to: o.points[0])
        for pt in o.points.dropFirst() { p.line(to: pt) }
        p.lineWidth = o.lineWidth
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        o.stroke.nsColor.setStroke(); p.stroke()
    }

    private static func drawHighlighter(_ o: MarkupObject) {
        NSGraphicsContext.current?.compositingOperation = .multiply
        let p = NSBezierPath(rect: o.frame)
        (o.fill ?? .highlighter).nsColor.setFill()
        p.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    // MARK: Text & images

    private static func drawText(_ o: MarkupObject) {
        guard !o.text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: o.fontSize, weight: .semibold),
            .foregroundColor: o.stroke.nsColor,
            .paragraphStyle: style,
        ]
        NSAttributedString(string: o.text, attributes: attrs).draw(in: o.frame)
    }

    private static func drawImage(_ o: MarkupObject) {
        guard let data = o.imageData, let img = NSImage(data: data) else { return }
        // Plain draw(in:) renders upright in a flipped context (matching how the
        // base image is drawn); the draw(in:from:…) variant double-flips it.
        img.draw(in: o.frame)
    }

    private static func drawPixelate(_ o: MarkupObject, baseImage: NSImage?) {
        guard let base = baseImage, o.frame.width > 1, o.frame.height > 1 else {
            // No base to sample — show a placeholder so the region is visible.
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: o.frame).fill()
            return
        }
        // The source rect is in the base image's coordinate space, which is
        // bottom-left origin — flip our top-left frame's Y to sample the right area.
        let src = CGRect(x: o.frame.minX,
                         y: base.size.height - o.frame.maxY,
                         width: o.frame.width, height: o.frame.height)

        // Downscale the region, then draw it back with no interpolation → blocky.
        let block: CGFloat = 9
        let small = NSSize(width: max((o.frame.width / block).rounded(), 2),
                           height: max((o.frame.height / block).rounded(), 2))
        let tiny = NSImage(size: small)
        tiny.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: small), from: src,
                  operation: .copy, fraction: 1)
        tiny.unlockFocus()

        NSGraphicsContext.current?.imageInterpolation = .none
        tiny.draw(in: o.frame)
        NSGraphicsContext.current?.imageInterpolation = .default
    }
}
