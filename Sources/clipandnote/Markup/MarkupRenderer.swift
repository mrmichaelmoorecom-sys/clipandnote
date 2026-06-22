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
        case .doubleArrow: drawDoubleArrow(obj)
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

    /// A curved double-arrow as one filled polygon — same visual style as the
    /// single arrow (tapered shaft, swept-back heads, contrast outline) but
    /// curved along the quadratic bezier defined by points[0/1/2].
    private static func drawDoubleArrow(_ o: MarkupObject) {
        let pts = doubleArrowPolygon(o)
        guard pts.count >= 3 else { return }
        let path = NSBezierPath()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.line(to: pt) }
        path.close()
        path.lineJoinStyle = .round

        contrastColor(for: o.stroke.nsColor).setStroke()
        path.lineWidth = 3
        path.stroke()
        o.stroke.nsColor.setFill()
        path.fill()
    }

    /// The tapered-shaft + swept-back-head outline as one polygon, following
    /// the quadratic bezier between points[0] and points[2] via points[1].
    /// Symmetric: thin in the middle (tailHalf), thicker at the head bases
    /// (baseHalf), with the same swept-back arrowhead at each tip. Shared by
    /// the canvas/PDF renderer and the SVG exporter.
    static func doubleArrowPolygon(_ o: MarkupObject) -> [CGPoint] {
        guard o.points.count >= 3 else { return [] }
        let p0 = o.points[0], cp = o.points[1], p2 = o.points[2]
        let lw = max(o.lineWidth, 2)
        let tailHalf = lw * 0.35
        let baseHalf = lw * 0.72
        let headHalf = max(lw * 2.1, 9)

        // Total bezier arc length (numerical), so we can keep heads in
        // proportion and clamp them for very short connectors.
        let curveLen = bezierLength(p0, cp, p2, samples: 24)
        guard curveLen > 4 else { return [] }
        let headLen = min(max(lw * 4.2, 18), curveLen * 0.4)
        let sweep = headLen * 0.28
        let tHead = headLen / curveLen   // approx. bezier-t of each head base

        // Unit tangent at each endpoint, pointing INTO the curve (toward cp).
        let d01 = CGPoint(x: cp.x - p0.x, y: cp.y - p0.y)
        let d21 = CGPoint(x: cp.x - p2.x, y: cp.y - p2.y)
        let l01 = max(0.5, hypot(d01.x, d01.y))
        let l21 = max(0.5, hypot(d21.x, d21.y))
        let ux0 = d01.x / l01, uy0 = d01.y / l01
        let ux2 = d21.x / l21, uy2 = d21.y / l21
        let px0 = -uy0, py0 = ux0
        let px2 = -uy2, py2 = ux2

        // Head base + swept shoulder centres (along the inward tangent).
        let b0 = CGPoint(x: p0.x + ux0 * headLen, y: p0.y + uy0 * headLen)
        let s0 = CGPoint(x: b0.x + ux0 * sweep,   y: b0.y + uy0 * sweep)
        let b2 = CGPoint(x: p2.x + ux2 * headLen, y: p2.y + uy2 * headLen)
        let s2 = CGPoint(x: b2.x + ux2 * sweep,   y: b2.y + uy2 * sweep)

        // Sample the shaft along the bezier between the two head bases (in
        // bezier-t space). For each sample compute the perpendicular and the
        // current half-width (linear taper: baseHalf → tailHalf → baseHalf).
        let N = 24
        var topShaft: [CGPoint] = []
        var bottomShaft: [CGPoint] = []
        for i in 1..<N {
            let f = CGFloat(i) / CGFloat(N)
            let t = tHead + f * (1 - 2 * tHead)
            let pt = bezierPoint(p0, cp, p2, t)
            let tan = bezierTangent(p0, cp, p2, t)
            let tl = max(0.5, hypot(tan.x, tan.y))
            let nx = -tan.y / tl, ny = tan.x / tl
            let half = tailHalf + (baseHalf - tailHalf) * abs(2 * f - 1)
            topShaft.append(CGPoint(x: pt.x + nx * half, y: pt.y + ny * half))
            bottomShaft.append(CGPoint(x: pt.x - nx * half, y: pt.y - ny * half))
        }

        var poly: [CGPoint] = []
        // Head 1 (tip → swept shoulder → base, on the "top" perpendicular)
        poly.append(p0)
        poly.append(CGPoint(x: s0.x + px0 * headHalf, y: s0.y + py0 * headHalf))
        poly.append(CGPoint(x: b0.x + px0 * baseHalf, y: b0.y + py0 * baseHalf))
        // Top of shaft, head1 → head2
        poly.append(contentsOf: topShaft)
        // Head 2 base, swept shoulder, tip (top side)
        poly.append(CGPoint(x: b2.x + px2 * baseHalf, y: b2.y + py2 * baseHalf))
        poly.append(CGPoint(x: s2.x + px2 * headHalf, y: s2.y + py2 * headHalf))
        poly.append(p2)
        // Bottom of head 2 (swept shoulder, base)
        poly.append(CGPoint(x: s2.x - px2 * headHalf, y: s2.y - py2 * headHalf))
        poly.append(CGPoint(x: b2.x - px2 * baseHalf, y: b2.y - py2 * baseHalf))
        // Bottom of shaft, head2 → head1 (reverse)
        poly.append(contentsOf: bottomShaft.reversed())
        // Bottom of head 1 (base, swept shoulder) → back to tip
        poly.append(CGPoint(x: b0.x - px0 * baseHalf, y: b0.y - py0 * baseHalf))
        poly.append(CGPoint(x: s0.x - px0 * headHalf, y: s0.y - py0 * headHalf))
        return poly
    }

    // MARK: Quadratic-bezier helpers

    private static func bezierPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint,
                                    _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u*u*p0.x + 2*u*t*p1.x + t*t*p2.x,
                       y: u*u*p0.y + 2*u*t*p1.y + t*t*p2.y)
    }

    private static func bezierTangent(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint,
                                      _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: 2*u*(p1.x - p0.x) + 2*t*(p2.x - p1.x),
                       y: 2*u*(p1.y - p0.y) + 2*t*(p2.y - p1.y))
    }

    /// Numerical arc length of the quadratic bezier (uniform-t sampling).
    private static func bezierLength(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint,
                                     samples: Int) -> CGFloat {
        var len: CGFloat = 0
        var prev = p0
        for i in 1...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let cur = bezierPoint(p0, p1, p2, t)
            len += hypot(cur.x - prev.x, cur.y - prev.y)
            prev = cur
        }
        return len
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
        let attrs: [NSAttributedString.Key: Any] = [
            .font: o.resolvedFont(),
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
