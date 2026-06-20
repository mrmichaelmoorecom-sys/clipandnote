import AppKit

/// Draws markup objects using AppKit primitives into the *current* graphics
/// context, assuming a flipped (top-left origin) coordinate space — which matches
/// both the on-screen `CanvasView` and the offscreen export context (Phase 3).
/// Keeping all drawing here means the editor and the exporter render identically.
enum MarkupRenderer {

    static func draw(_ obj: MarkupObject, baseImage: NSImage?) {
        switch obj.kind {
        case .rectangle:   withHalo(obj.stroke.nsColor) { drawRect(obj) }
        case .ellipse:     withHalo(obj.stroke.nsColor) { drawEllipse(obj) }
        case .line:        withHalo(obj.stroke.nsColor) { drawLine(obj) }
        case .arrow:       withHalo(obj.stroke.nsColor) { drawArrow(obj) }
        case .freehand:    withHalo(obj.stroke.nsColor) { drawFreehand(obj) }
        case .text:        withHalo(obj.stroke.nsColor) { drawText(obj) }
        case .highlighter: drawHighlighter(obj)   // translucent — no halo
        case .image:       drawImage(obj)
        case .pixelate:    drawPixelate(obj, baseImage: baseImage)
        }
    }

    // MARK: Legibility halo

    /// A soft, contrast-aware glow behind a mark so it stays legible on any
    /// background. The halo color is chosen by (partial-WCAG) relative luminance:
    /// dark marks get a light halo, light marks get a dark one.
    static func haloColor(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.6 ? .black : .white
    }

    private static func withHalo(_ color: NSColor, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = haloColor(for: color).withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
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

    /// One cohesive filled arrow polygon — shaft and head share the same path, so
    /// the head can never drift out of alignment with the line, and it scales
    /// cleanly with line width.
    private static func drawArrow(_ o: MarkupObject) {
        guard o.points.count >= 2 else { return }
        let s = o.points[0], e = o.points[1]
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }

        let ux = dx / len, uy = dy / len          // unit direction
        let px = -uy, py = ux                      // unit perpendicular
        let half = max(o.lineWidth, 2) / 2         // shaft half-thickness
        let headLen = min(max(o.lineWidth * 3.4, 16), len * 0.6)
        let headHalf = max(o.lineWidth * 1.7, headLen * 0.45)
        let bx = e.x - ux * headLen, by = e.y - uy * headLen   // head base center

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let path = NSBezierPath()
        path.move(to: p(s.x + px * half, s.y + py * half))
        path.line(to: p(bx + px * half, by + py * half))
        path.line(to: p(bx + px * headHalf, by + py * headHalf))   // head shoulder
        path.line(to: p(e.x, e.y))                                 // tip
        path.line(to: p(bx - px * headHalf, by - py * headHalf))
        path.line(to: p(bx - px * half, by - py * half))
        path.line(to: p(s.x - px * half, s.y - py * half))
        path.close()
        path.lineJoinStyle = .round

        o.stroke.nsColor.setFill()
        path.fill()
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
