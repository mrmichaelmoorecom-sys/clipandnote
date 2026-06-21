import AppKit

/// Draws markup objects using AppKit primitives into the *current* graphics
/// context, assuming a flipped (top-left origin) coordinate space — which matches
/// both the on-screen `CanvasView` and the offscreen export context (Phase 3).
/// Keeping all drawing here means the editor and the exporter render identically.
enum MarkupRenderer {

    static func draw(_ obj: MarkupObject, baseImage: NSImage?, baseFrame: CGRect) {
        switch obj.kind {
        case .rectangle:   drawRect(obj)
        case .ellipse:     drawEllipse(obj)
        case .line:        drawLine(obj)
        case .arrow:       drawArrow(obj)
        case .freehand:    drawFreehand(obj)
        case .text:        drawText(obj)
        case .highlighter: drawHighlighter(obj)   // translucent — no contrast edge
        case .image:       drawImage(obj)
        case .pixelate:    drawPixelate(obj, baseImage: baseImage, baseFrame: baseFrame)
        }
    }

    /// A contrast color chosen by (partial-WCAG) relative luminance: dark marks
    /// get a light edge, light marks get a dark one — so a mark stays legible on
    /// any background.
    static func contrastColor(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.6 ? NSColor(white: 0.05, alpha: 1) : .white
    }

    /// Width of the contrasting outline drawn beneath a stroked mark.
    static func outlineWidth(_ lineWidth: CGFloat) -> CGFloat { lineWidth + max(lineWidth * 0.9, 3) }

    // MARK: Stroked shapes (outline underlay → colored stroke)

    private static func strokeWithContrast(_ path: NSBezierPath, _ o: MarkupObject) {
        if let fill = o.fill { fill.nsColor.setFill(); path.fill() }
        path.lineWidth = outlineWidth(o.lineWidth)
        contrastColor(for: o.stroke.nsColor).setStroke(); path.stroke()
        path.lineWidth = o.lineWidth
        o.stroke.nsColor.setStroke(); path.stroke()
    }

    private static func drawRect(_ o: MarkupObject) {
        strokeWithContrast(NSBezierPath(rect: o.frame), o)
    }

    private static func drawEllipse(_ o: MarkupObject) {
        strokeWithContrast(NSBezierPath(ovalIn: o.frame), o)
    }

    private static func drawLine(_ o: MarkupObject) {
        guard o.points.count >= 2 else { return }
        let p = NSBezierPath()
        p.move(to: o.points[0]); p.line(to: o.points[1])
        p.lineCapStyle = .round
        strokeWithContrast(p, o)
    }

    private static func drawFreehand(_ o: MarkupObject) {
        guard o.points.count >= 2 else { return }
        let p = NSBezierPath()
        p.move(to: o.points[0])
        for pt in o.points.dropFirst() { p.line(to: pt) }
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        strokeWithContrast(p, o)
    }

    /// A single filled arrow with a tapered shaft and a swept-back head — one
    /// path, so the head can't drift, and a contrasting outline so it pops.
    /// The arrow outline as one polygon (tapered shaft + swept-back head). Shared
    /// by the canvas/PDF renderer and the SVG exporter so they stay identical.
    static func arrowPolygon(_ o: MarkupObject) -> [CGPoint] {
        guard o.points.count >= 2 else { return [] }
        let s = o.points[0], e = o.points[1]
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return [] }

        let ux = dx / len, uy = dy / len          // unit direction
        let px = -uy, py = ux                      // unit perpendicular
        let lw = max(o.lineWidth, 2)
        let tailHalf = lw * 0.35                    // thin at the tail
        let baseHalf = lw * 0.72                    // thicker where it meets the head
        let headHalf = max(lw * 2.1, 9)
        let headLen = min(max(lw * 4.2, 18), len * 0.6)
        let bx = e.x - ux * headLen, by = e.y - uy * headLen          // head base
        let sweep = headLen * 0.28                                    // swept-back shoulders
        let sx = bx - ux * sweep, sy = by - uy * sweep
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        return [
            p(s.x + px * tailHalf, s.y + py * tailHalf),
            p(bx + px * baseHalf, by + py * baseHalf),
            p(sx + px * headHalf, sy + py * headHalf),   // swept shoulder
            p(e.x, e.y),                                 // tip
            p(sx - px * headHalf, sy - py * headHalf),
            p(bx - px * baseHalf, by - py * baseHalf),
            p(s.x - px * tailHalf, s.y - py * tailHalf),
        ]
    }

    private static func drawArrow(_ o: MarkupObject) {
        let pts = arrowPolygon(o)
        guard pts.count >= 3 else { return }
        let path = NSBezierPath()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.line(to: pt) }
        path.close()
        path.lineJoinStyle = .round

        // Contrasting outline, then the colored fill.
        contrastColor(for: o.stroke.nsColor).setStroke()
        path.lineWidth = 3
        path.stroke()
        o.stroke.nsColor.setFill()
        path.fill()
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
        // Negative strokeWidth → fill the glyphs AND stroke them with the contrast
        // color, giving an outlined label that reads on any background.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: o.resolvedFont(),
            .foregroundColor: o.stroke.nsColor,
            .strokeColor: contrastColor(for: o.stroke.nsColor),
            .strokeWidth: -3.0,
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

    private static func drawPixelate(_ o: MarkupObject, baseImage: NSImage?, baseFrame: CGRect) {
        guard let base = baseImage, o.frame.width > 1, o.frame.height > 1 else {
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: o.frame).fill()
            return
        }
        // Map the canvas-space frame into the base image's own (bottom-left
        // origin) coordinate space, accounting for where the base sits.
        let localX = o.frame.minX - baseFrame.minX
        let localMaxY = o.frame.maxY - baseFrame.minY
        let src = CGRect(x: localX,
                         y: base.size.height - localMaxY,
                         width: o.frame.width, height: o.frame.height)
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
