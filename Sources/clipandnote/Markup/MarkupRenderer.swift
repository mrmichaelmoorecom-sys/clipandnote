import AppKit

/// Draws markup objects using AppKit primitives into the *current* graphics
/// context, assuming a flipped (top-left origin) coordinate space — which matches
/// both the on-screen `CanvasView` and the offscreen export context (Phase 3).
/// Keeping all drawing here means the editor and the exporter render identically.
enum MarkupRenderer {

    static func draw(_ obj: MarkupObject, baseImage: NSImage?, baseFrame: CGRect) {
        // For stroke-and-fill marks (everything except highlighter / image /
        // pixelate), the contrast outline and the coloured body overlap. If
        // we just lowered each colour's alpha they'd composite at different
        // effective opacities (boundary 0.75, interior 0.5). Instead, wrap
        // the whole mark in a CG transparency layer with global setAlpha:
        // the inner draws run at full opacity into the layer, then the
        // layer composites at the desired alpha exactly once. Highlighter
        // already uses translucent fill + multiply, image / pixelate are
        // intentionally opaque.
        let ctx = NSGraphicsContext.current?.cgContext
        let needsLayer: Bool
        switch obj.kind {
        case .image, .pixelate, .highlighter: needsLayer = false
        default: needsLayer = obj.stroke.a < 1.0
        }
        if needsLayer, let ctx {
            ctx.saveGState()
            ctx.setAlpha(obj.stroke.a)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
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
        case .ruler:       drawRuler(obj)
        case .angle:       drawAngle(obj)
        }
        if needsLayer, let ctx {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
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
        if let fill = o.fill { fill.opaqueColor.setFill(); path.fill() }
        path.lineWidth = outlineWidth(o.lineWidth)
        contrastColor(for: o.stroke.opaqueColor).setStroke(); path.stroke()
        path.lineWidth = o.lineWidth
        o.stroke.opaqueColor.setStroke(); path.stroke()
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

    /// Graduated ruler tick half-height for a tick `n` pixels from the start:
    /// tiny every 5px, taller at 10 / 50 / 100. nil = no tick at `n`.
    static func rulerTickFraction(_ n: Int) -> CGFloat? {
        if n % 100 == 0 { return 0.85 }
        if n % 50  == 0 { return 0.58 }
        if n % 10  == 0 { return 0.40 }
        if n % 5   == 0 { return 0.22 }
        return nil
    }

    /// A dimension ruler: baseline a→b, perpendicular end caps, graduated tick
    /// hatches (tiny every 5px, taller at 10/50/100), a direction arrowhead
    /// just past the end, and a "<N> px" length label above the midpoint. N is
    /// the straight-line distance in canvas pixels (the canvas is 1:1 with the
    /// snapshot, so it reads true).
    private static func drawRuler(_ o: MarkupObject) {
        guard o.points.count >= 2 else { return }
        let a = o.points[0], b = o.points[1]
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length      // unit direction
        let nx = -uy, ny = ux                        // unit perpendicular

        let lw = o.lineWidth
        let color = o.stroke.opaqueColor             // alpha handled by the layer
        let contrast = contrastColor(for: o.stroke.nsColor)

        // Stroke a tiny path with the contrast underlay, then the colour.
        func stroked(width: CGFloat, _ build: (NSBezierPath) -> Void) {
            let p = NSBezierPath(); p.lineCapStyle = .round; build(p)
            p.lineWidth = width + max(width * 0.9, 3); contrast.setStroke(); p.stroke()
            p.lineWidth = width; color.setStroke(); p.stroke()
        }

        let capHalf = max(8, lw * 2.5)

        // Arrowhead FIRST (bottom layer), just past the end — so the end cap
        // and ticks render on top of it instead of the arrow covering them.
        let headLen = max(12, lw * 3.5)
        let headHalf = max(7, lw * 2)
        let tip = CGPoint(x: b.x + ux * headLen, y: b.y + uy * headLen)
        let left = CGPoint(x: b.x + nx * headHalf, y: b.y + ny * headHalf)
        let right = CGPoint(x: b.x - nx * headHalf, y: b.y - ny * headHalf)
        let head = NSBezierPath()
        head.move(to: tip); head.line(to: left); head.line(to: right); head.close()
        head.lineJoinStyle = .round
        contrast.setStroke(); head.lineWidth = max(1.4, lw * 0.5); head.stroke()
        color.setFill(); head.fill()

        // Baseline.
        stroked(width: lw) { $0.move(to: a); $0.line(to: b) }

        // Perpendicular end caps at both ends.
        for pt in [a, b] {
            let c0 = CGPoint(x: pt.x + nx * capHalf, y: pt.y + ny * capHalf)
            let c1 = CGPoint(x: pt.x - nx * capHalf, y: pt.y - ny * capHalf)
            stroked(width: lw) { $0.move(to: c0); $0.line(to: c1) }
        }

        // Graduated tick hatches along the baseline, centered, with a thin
        // contrast halo. Skip ticks too close to either end cap.
        let tickW = max(1, lw * 0.6)
        func tick(_ n: Int) {
            guard CGFloat(n) > 2, length - CGFloat(n) > 2,
                  let frac = rulerTickFraction(n) else { return }
            let h = capHalf * frac
            let m = CGPoint(x: a.x + ux * CGFloat(n), y: a.y + uy * CGFloat(n))
            let t0 = CGPoint(x: m.x + nx * h, y: m.y + ny * h)
            let t1 = CGPoint(x: m.x - nx * h, y: m.y - ny * h)
            let p = NSBezierPath(); p.move(to: t0); p.line(to: t1); p.lineCapStyle = .round
            p.lineWidth = tickW + 1.5; contrast.setStroke(); p.stroke()
            p.lineWidth = tickW; color.setStroke(); p.stroke()
        }
        var n = 5
        while CGFloat(n) < length { tick(n); n += 5 }

        // Length label above the midpoint.
        drawRulerLabel("\(Int(length.rounded())) px",
                       mid: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                       perp: CGPoint(x: nx, y: ny), o: o)
    }

    /// Horizontal (screen-aligned) length label with an 8-direction contrast
    /// halo so it reads on any background, offset above the baseline.
    private static func drawRulerLabel(_ text: String, mid: CGPoint, perp: CGPoint, o: MarkupObject) {
        let font = NSFont.systemFont(ofSize: max(13, o.lineWidth * 3.5), weight: .bold)
        let fill = o.stroke.opaqueColor
        let outline = contrastColor(for: o.stroke.nsColor)
        let ns = text as NSString
        let size = ns.size(withAttributes: [.font: font])
        // Push above the line along the perpendicular. Canvas is flipped
        // (top-left origin), so "above" = subtract the perpendicular.
        let off = 14 + size.height / 2
        let center = CGPoint(x: mid.x - perp.x * off, y: mid.y - perp.y * off)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let r: CGFloat = 2.5
        let haloAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: outline]
        for ang in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4) {
            ns.draw(at: CGPoint(x: origin.x + CGFloat(cos(ang)) * r,
                                y: origin.y + CGFloat(sin(ang)) * r),
                    withAttributes: haloAttrs)
        }
        ns.draw(at: origin, withAttributes: [.font: font, .foregroundColor: fill])
    }

    /// Screen-aligned label centered at `center`, with the same 8-direction
    /// contrast halo (used by the angle tool).
    private static func drawHaloLabel(_ text: String, center: CGPoint, o: MarkupObject) {
        let font = NSFont.systemFont(ofSize: max(13, o.lineWidth * 3.5), weight: .bold)
        let fill = o.stroke.opaqueColor
        let outline = contrastColor(for: o.stroke.nsColor)
        let ns = text as NSString
        let size = ns.size(withAttributes: [.font: font])
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let r: CGFloat = 2.5
        let halo: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: outline]
        for ang in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4) {
            ns.draw(at: CGPoint(x: origin.x + CGFloat(cos(ang)) * r,
                                y: origin.y + CGFloat(sin(ang)) * r), withAttributes: halo)
        }
        ns.draw(at: origin, withAttributes: [.font: font, .foregroundColor: fill])
    }

    /// An angle measurement: two legs from the vertex (points[1]), an arc
    /// spanning the interior angle, and a "<N>°" label on the bisector.
    private static func drawAngle(_ o: MarkupObject) {
        guard o.points.count >= 3 else { return }
        let a = o.points[0], v = o.points[1], b = o.points[2]
        let lw = o.lineWidth
        let color = o.stroke.opaqueColor
        let contrast = contrastColor(for: o.stroke.nsColor)

        func stroked(width: CGFloat, _ build: (NSBezierPath) -> Void) {
            let p = NSBezierPath(); p.lineCapStyle = .round; build(p)
            p.lineWidth = width + max(width * 0.9, 3); contrast.setStroke(); p.stroke()
            p.lineWidth = width; color.setStroke(); p.stroke()
        }

        // Two legs from the vertex.
        stroked(width: lw) { $0.move(to: v); $0.line(to: a) }
        stroked(width: lw) { $0.move(to: v); $0.line(to: b) }

        // Interior angle between the two rays.
        let ang1 = atan2(a.y - v.y, a.x - v.x)
        let ang2 = atan2(b.y - v.y, b.x - v.x)
        var diff = ang2 - ang1
        while diff <= -.pi { diff += 2 * .pi }
        while diff > .pi { diff -= 2 * .pi }
        let deg = abs(diff) * 180 / .pi

        // Arc at the vertex, drawn as a sampled polyline (avoids flipped-coord
        // arc-direction ambiguity).
        let legLen = min(hypot(a.x - v.x, a.y - v.y), hypot(b.x - v.x, b.y - v.y))
        let radius = max(14, min(legLen * 0.4, 44))
        if legLen > 4 {
            stroked(width: max(1, lw * 0.8)) { p in
                let steps = 40
                for i in 0...steps {
                    let ang = ang1 + diff * CGFloat(i) / CGFloat(steps)
                    let pt = CGPoint(x: v.x + cos(ang) * radius, y: v.y + sin(ang) * radius)
                    if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
                }
            }
            // Degree label just beyond the arc, on the bisector.
            let bis = ang1 + diff / 2
            let lr = radius + 16
            drawHaloLabel("\(Int(deg.rounded()))°",
                          center: CGPoint(x: v.x + cos(bis) * lr, y: v.y + sin(bis) * lr), o: o)
        }
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

        contrastColor(for: o.stroke.opaqueColor).setStroke()
        path.lineWidth = 3
        path.stroke()
        o.stroke.opaqueColor.setFill()
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
        contrastColor(for: o.stroke.opaqueColor).setStroke()
        path.lineWidth = 3
        path.stroke()
        o.stroke.opaqueColor.setFill()
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
        let fill = o.stroke.opaqueColor
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
