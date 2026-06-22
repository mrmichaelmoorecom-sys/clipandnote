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
    /// Every key point (head base, swept shoulder, shaft samples) sits ON the
    /// bezier with its perpendicular derived from the bezier tangent at that
    /// t-value, so adjacent vertices align cleanly — no notches at the heads.
    /// Symmetric: thin tailHalf in the middle, thicker baseHalf at each head
    /// base; the same swept-back arrowhead at each tip. Shared by the canvas
    /// renderer and the SVG exporter.
    static func doubleArrowPolygon(_ o: MarkupObject) -> [CGPoint] {
        guard o.points.count >= 3 else { return [] }
        let p0 = o.points[0], cp = o.points[1], p2 = o.points[2]
        let lw = max(o.lineWidth, 2)
        let tailHalf = lw * 0.35
        let baseHalf = lw * 0.72
        let headHalf = max(lw * 2.1, 9)

        // Bezier arc length (numerical) so head proportions read right at any
        // curve scale, and we can clamp to leave room for the shaft.
        let curveLen = bezierLength(p0, cp, p2, samples: 24)
        guard curveLen > 4 else { return [] }
        // Cap headLen so the two shoulders (each at headLen + sweep along the
        // curve) sit well inside their own half — keeps heads from overlapping
        // on very short connectors.
        let headLen = min(max(lw * 4.2, 18), curveLen * 0.35)
        let sweep = headLen * 0.28
        let tHead     = headLen           / curveLen   // bezier-t of head base
        let tShoulder = (headLen + sweep) / curveLen   // bezier-t of swept shoulder

        // Position + perpendicular (unit, rotated 90° CCW from tangent) at any t.
        func ptAndPerp(_ t: CGFloat) -> (pt: CGPoint, px: CGFloat, py: CGFloat) {
            let p = bezierPoint(p0, cp, p2, t)
            let tan = bezierTangent(p0, cp, p2, t)
            let tl = max(0.5, hypot(tan.x, tan.y))
            return (p, -tan.y / tl, tan.x / tl)
        }
        let h1Shoulder = ptAndPerp(tShoulder)
        let h2Shoulder = ptAndPerp(1 - tShoulder)

        // Sample the shaft INCLUDING the endpoints (head bases). Width tapers
        // baseHalf at f=0/1 → tailHalf at f=0.5, so the first/last shaft point
        // line up exactly with where each head base would land separately —
        // means no separate base vertex, no discontinuity.
        let N = 24
        var topShaft: [CGPoint] = []
        var bottomShaft: [CGPoint] = []
        for i in 0...N {
            let f = CGFloat(i) / CGFloat(N)
            let t = tHead + f * (1 - 2 * tHead)
            let s = ptAndPerp(t)
            let half = tailHalf + (baseHalf - tailHalf) * abs(2 * f - 1)
            topShaft.append(CGPoint(x: s.pt.x + s.px * half, y: s.pt.y + s.py * half))
            bottomShaft.append(CGPoint(x: s.pt.x - s.px * half, y: s.pt.y - s.py * half))
        }

        // Walk the polygon: tip → swept shoulder → shaft top → swept shoulder
        // → tip → mirror back. Shoulder sits FURTHER into the curve than the
        // head base (per the single-arrow style: swept-back), so the fold from
        // shoulder to base produces the same swallowtail silhouette.
        var poly: [CGPoint] = []
        poly.append(p0)
        poly.append(CGPoint(x: h1Shoulder.pt.x + h1Shoulder.px * headHalf,
                            y: h1Shoulder.pt.y + h1Shoulder.py * headHalf))
        poly.append(contentsOf: topShaft)   // first = base1 top, last = base2 top
        poly.append(CGPoint(x: h2Shoulder.pt.x + h2Shoulder.px * headHalf,
                            y: h2Shoulder.pt.y + h2Shoulder.py * headHalf))
        poly.append(p2)
        poly.append(CGPoint(x: h2Shoulder.pt.x - h2Shoulder.px * headHalf,
                            y: h2Shoulder.pt.y - h2Shoulder.py * headHalf))
        poly.append(contentsOf: bottomShaft.reversed())
        poly.append(CGPoint(x: h1Shoulder.pt.x - h1Shoulder.px * headHalf,
                            y: h1Shoulder.pt.y - h1Shoulder.py * headHalf))
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

        // Outline-only style: stroke the glyphs in the chosen colour, no fill.
        if o.textOutlined == true {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: o.resolvedFont(),
                .foregroundColor: NSColor.clear,
                .strokeColor: o.stroke.nsColor,
                .strokeWidth: max(2.0, o.fontSize * 0.06),  // positive → stroke only
                .paragraphStyle: style,
            ]
            NSAttributedString(string: o.text, attributes: attrs).draw(in: o.frame)
            return
        }

        let fill = o.stroke.nsColor
        let outline = contrastColor(for: fill)

        // Outline radius: a sensible % of font size, clamped so tiny text still
        // gets a readable contour and giant text doesn't get cartoonish.
        let r = max(1.5, min(o.fontSize * 0.05, 6))

        // Multi-direction offset render: stamp the contrast-coloured text at
        // 8 positions around the centre, then fill on top. Unlike a per-glyph
        // strokeWidth, only the OUTER edge of the halo is exposed — the inner
        // edge gets fully covered by the fill, so there's no fringe ringing
        // the glyph interior.
        let outlineAttrs: [NSAttributedString.Key: Any] = [
            .font: o.resolvedFont(),
            .foregroundColor: outline,
            .paragraphStyle: style,
        ]
        let outlineString = NSAttributedString(string: o.text, attributes: outlineAttrs)
        let angles: [CGFloat] = [0, 45, 90, 135, 180, 225, 270, 315]
        for deg in angles {
            let rad = deg * .pi / 180
            outlineString.draw(in: o.frame.offsetBy(dx: cos(rad) * r, dy: sin(rad) * r))
        }

        let fillAttrs: [NSAttributedString.Key: Any] = [
            .font: o.resolvedFont(),
            .foregroundColor: fill,
            .paragraphStyle: style,
        ]
        NSAttributedString(string: o.text, attributes: fillAttrs).draw(in: o.frame)
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
