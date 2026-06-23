import AppKit

/// Exports a markup document to SVG — true open vector that opens in browsers and
/// design tools. SVG is top-left origin like the canvas, so no flipping. The base
/// snapshot and pasted images embed as base64 PNG; pixelate regions embed as a
/// small pixelated PNG.
enum SVGExporter {

    static func svg(_ doc: MarkupDocument) -> String {
        let w = num(doc.canvasSize.width), h = num(doc.canvasSize.height)
        var body = "<rect x=\"0\" y=\"0\" width=\"\(w)\" height=\"\(h)\" fill=\"\(hex(doc.backgroundColor.nsColor))\"/>\n"
        if let png = doc.baseImage?.pngData() { body += image(png, doc.baseImageFrame, pixelated: false) }
        for object in doc.objects {
            body += element(object, base: doc.baseImage, baseFrame: doc.baseImageFrame)
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
        \(body)</svg>
        """
    }

    // MARK: Per-object

    private static func element(_ o: MarkupObject, base: NSImage?, baseFrame: CGRect) -> String {
        switch o.kind {
        case .rectangle:
            return stroked("<rect x=\"\(num(o.frame.minX))\" y=\"\(num(o.frame.minY))\" "
                + "width=\"\(num(o.frame.width))\" height=\"\(num(o.frame.height))\"", o, fillable: true)
        case .ellipse:
            return stroked("<ellipse cx=\"\(num(o.frame.midX))\" cy=\"\(num(o.frame.midY))\" "
                + "rx=\"\(num(o.frame.width / 2))\" ry=\"\(num(o.frame.height / 2))\"", o, fillable: true)
        case .line:
            guard o.points.count >= 2 else { return "" }
            return stroked("<line x1=\"\(num(o.points[0].x))\" y1=\"\(num(o.points[0].y))\" "
                + "x2=\"\(num(o.points[1].x))\" y2=\"\(num(o.points[1].y))\"", o, cap: "round")
        case .freehand:
            let pts = o.points.map { "\(num($0.x)),\(num($0.y))" }.joined(separator: " ")
            return stroked("<polyline points=\"\(pts)\"", o, cap: "round", join: "round")
        case .arrow:
            let pts = MarkupRenderer.arrowPolygon(o).map { "\(num($0.x)),\(num($0.y))" }.joined(separator: " ")
            guard !pts.isEmpty else { return "" }
            return "<polygon points=\"\(pts)\" fill=\"\(hex(o.stroke.nsColor))\" "
                + "stroke=\"\(hex(MarkupRenderer.contrastColor(for: o.stroke.nsColor)))\" "
                + "stroke-width=\"3\" stroke-linejoin=\"round\"/>\n"
        case .doubleArrow:
            let pts = MarkupRenderer.doubleArrowPolygon(o)
                .map { "\(num($0.x)),\(num($0.y))" }.joined(separator: " ")
            guard !pts.isEmpty else { return "" }
            return "<polygon points=\"\(pts)\" fill=\"\(hex(o.stroke.nsColor))\" "
                + "stroke=\"\(hex(MarkupRenderer.contrastColor(for: o.stroke.nsColor)))\" "
                + "stroke-width=\"3\" stroke-linejoin=\"round\"/>\n"
        case .highlighter:
            let fill = o.fill ?? .highlighter
            return "<rect x=\"\(num(o.frame.minX))\" y=\"\(num(o.frame.minY))\" "
                + "width=\"\(num(o.frame.width))\" height=\"\(num(o.frame.height))\" "
                + "fill=\"\(hex(fill.nsColor))\" fill-opacity=\"\(num(fill.a))\" "
                + "style=\"mix-blend-mode:multiply\"/>\n"
        case .ruler:
            return ruler(o)
        case .angle:
            return angle(o)
        case .text:
            return text(o)
        case .image:
            return o.imageData.map { image($0, o.frame, pixelated: false) } ?? ""
        case .pixelate:
            return pixelatePNG(o, base: base, baseFrame: baseFrame).map { image($0, o.frame, pixelated: true) } ?? ""
        }
    }

    /// A stroked shape: contrast outline underlay, then the colored stroke (and
    /// optional fill) — matching MarkupRenderer.
    private static func stroked(_ geom: String, _ o: MarkupObject,
                                cap: String? = nil, join: String? = nil, fillable: Bool = false) -> String {
        let lw = num(o.lineWidth), ow = num(MarkupRenderer.outlineWidth(o.lineWidth))
        let color = hex(o.stroke.nsColor), contrast = hex(MarkupRenderer.contrastColor(for: o.stroke.nsColor))
        let extra = (cap.map { " stroke-linecap=\"\($0)\"" } ?? "") + (join.map { " stroke-linejoin=\"\($0)\"" } ?? "")
        var out = ""
        if fillable, let fill = o.fill {
            out += "\(geom) fill=\"\(hex(fill.nsColor))\" fill-opacity=\"\(num(fill.a))\"/>\n"
        }
        out += "\(geom) fill=\"none\" stroke=\"\(contrast)\" stroke-width=\"\(ow)\"\(extra)/>\n"
        out += "\(geom) fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(lw)\"\(extra)/>\n"
        return out
    }

    private static func text(_ o: MarkupObject) -> String {
        let font = o.resolvedFont()
        let family = font.familyName ?? "sans-serif"
        let color = hex(o.stroke.nsColor)
        let contrast = hex(MarkupRenderer.contrastColor(for: o.stroke.nsColor))
        let x = num(o.frame.minX)
        let lines = o.text.components(separatedBy: "\n")
        let tspans = lines.enumerated().map { i, line in
            "<tspan x=\"\(x)\" dy=\"\(i == 0 ? "0" : num(o.fontSize * 1.2))\">\(escape(line))</tspan>"
        }.joined()
        let yBase = num(o.frame.minY + o.fontSize * 0.82)
        let common = "x=\"\(x)\" y=\"\(yBase)\" font-family=\"\(escape(family))\" "
            + "font-size=\"\(num(o.fontSize))\" font-weight=\"600\""
        // Filled with contrast outline (paint-order="stroke" → outline under fill).
        let sw = num(o.fontSize * 0.06)
        return "<text \(common) fill=\"\(color)\" stroke=\"\(contrast)\" "
            + "stroke-width=\"\(sw)\" stroke-linejoin=\"round\" "
            + "paint-order=\"stroke\">\(tspans)</text>\n"
    }

    /// Dimension ruler — baseline, caps, ticks, arrowhead, and the "<N> px"
    /// label, mirroring MarkupRenderer.drawRuler.
    private static func ruler(_ o: MarkupObject) -> String {
        guard o.points.count >= 2 else { return "" }
        let a = o.points[0], b = o.points[1]
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return "" }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let color = hex(o.stroke.nsColor)
        let contrast = hex(MarkupRenderer.contrastColor(for: o.stroke.nsColor))
        let lw = o.lineWidth, ow = MarkupRenderer.outlineWidth(o.lineWidth)

        func line(_ p0: CGPoint, _ p1: CGPoint, _ w: CGFloat) -> String {
            let g = "<line x1=\"\(num(p0.x))\" y1=\"\(num(p0.y))\" x2=\"\(num(p1.x))\" y2=\"\(num(p1.y))\""
            return "\(g) stroke=\"\(contrast)\" stroke-width=\"\(num(w + max(w*0.9,3)))\" stroke-linecap=\"round\"/>\n"
                + "\(g) stroke=\"\(color)\" stroke-width=\"\(num(w))\" stroke-linecap=\"round\"/>\n"
        }

        let capHalf = max(8, lw * 2.5)
        // Arrowhead FIRST (bottom layer) so the end cap + ticks sit on top.
        let headLen = max(12, lw*3.5), headHalf = max(7, lw*2)
        let tip = CGPoint(x: b.x + ux*headLen, y: b.y + uy*headLen)
        let l = CGPoint(x: b.x + nx*headHalf, y: b.y + ny*headHalf)
        let r = CGPoint(x: b.x - nx*headHalf, y: b.y - ny*headHalf)
        let pts = "\(num(tip.x)),\(num(tip.y)) \(num(l.x)),\(num(l.y)) \(num(r.x)),\(num(r.y))"
        var out = "<polygon points=\"\(pts)\" fill=\"\(color)\" stroke=\"\(contrast)\" "
            + "stroke-width=\"\(num(max(1.4, lw*0.5)))\" stroke-linejoin=\"round\"/>\n"
        out += line(a, b, lw)   // baseline
        for pt in [a, b] {
            out += line(CGPoint(x: pt.x + nx*capHalf, y: pt.y + ny*capHalf),
                        CGPoint(x: pt.x - nx*capHalf, y: pt.y - ny*capHalf), lw)
        }
        // Graduated tick hatches (tiny every 5px, taller at 10/50/100).
        let tickW = max(1, lw * 0.6)
        var nTick = 5
        while CGFloat(nTick) < length {
            if CGFloat(nTick) > 2, length - CGFloat(nTick) > 2,
               let frac = MarkupRenderer.rulerTickFraction(nTick) {
                let h = capHalf * frac
                let m = CGPoint(x: a.x + ux*CGFloat(nTick), y: a.y + uy*CGFloat(nTick))
                out += line(CGPoint(x: m.x + nx*h, y: m.y + ny*h),
                            CGPoint(x: m.x - nx*h, y: m.y - ny*h), tickW)
            }
            nTick += 5
        }
        // Label above the midpoint.
        let fontSize = max(13, lw * 3.5)
        let off = 14 + fontSize / 2
        let mid = CGPoint(x: (a.x+b.x)/2 - nx*off, y: (a.y+b.y)/2 - ny*off + fontSize*0.35)
        out += "<text x=\"\(num(mid.x))\" y=\"\(num(mid.y))\" text-anchor=\"middle\" "
            + "font-family=\"sans-serif\" font-size=\"\(num(fontSize))\" font-weight=\"700\" "
            + "fill=\"\(color)\" stroke=\"\(contrast)\" stroke-width=\"\(num(fontSize*0.12))\" "
            + "stroke-linejoin=\"round\" paint-order=\"stroke\">\(Int(length.rounded())) px</text>\n"
        return out
    }

    /// Angle measurement — two legs, an arc, and a "<N>°" label.
    private static func angle(_ o: MarkupObject) -> String {
        guard o.points.count >= 3 else { return "" }
        let a = o.points[0], v = o.points[1], b = o.points[2]
        let color = hex(o.stroke.nsColor)
        let contrast = hex(MarkupRenderer.contrastColor(for: o.stroke.nsColor))
        let lw = o.lineWidth

        func line(_ p0: CGPoint, _ p1: CGPoint, _ w: CGFloat) -> String {
            let g = "<line x1=\"\(num(p0.x))\" y1=\"\(num(p0.y))\" x2=\"\(num(p1.x))\" y2=\"\(num(p1.y))\""
            return "\(g) stroke=\"\(contrast)\" stroke-width=\"\(num(w + max(w*0.9,3)))\" stroke-linecap=\"round\"/>\n"
                + "\(g) stroke=\"\(color)\" stroke-width=\"\(num(w))\" stroke-linecap=\"round\"/>\n"
        }

        var out = line(v, a, lw) + line(v, b, lw)
        let ang1 = atan2(a.y - v.y, a.x - v.x)
        let ang2 = atan2(b.y - v.y, b.x - v.x)
        var diff = ang2 - ang1
        while diff <= -.pi { diff += 2 * .pi }
        while diff >  .pi { diff -= 2 * .pi }
        let deg = abs(diff) * 180 / .pi
        let legLen = min(hypot(a.x-v.x, a.y-v.y), hypot(b.x-v.x, b.y-v.y))
        let radius = max(14, min(legLen * 0.4, 44))
        if legLen > 4 {
            // Arc as a polyline.
            var pts: [String] = []
            for i in 0...40 {
                let ang = ang1 + diff * CGFloat(i) / 40
                pts.append("\(num(v.x + cos(ang)*radius)),\(num(v.y + sin(ang)*radius))")
            }
            let aw = max(1, lw * 0.8)
            let poly = "<polyline points=\"\(pts.joined(separator: " "))\" fill=\"none\""
            out += "\(poly) stroke=\"\(contrast)\" stroke-width=\"\(num(aw + max(aw*0.9,3)))\" stroke-linecap=\"round\"/>\n"
            out += "\(poly) stroke=\"\(color)\" stroke-width=\"\(num(aw))\" stroke-linecap=\"round\"/>\n"
            // Label.
            let bis = ang1 + diff / 2
            let lr = radius + 16
            let fontSize = max(13, lw * 3.5)
            let lp = CGPoint(x: v.x + cos(bis)*lr, y: v.y + sin(bis)*lr + fontSize*0.35)
            out += "<text x=\"\(num(lp.x))\" y=\"\(num(lp.y))\" text-anchor=\"middle\" "
                + "font-family=\"sans-serif\" font-size=\"\(num(fontSize))\" font-weight=\"700\" "
                + "fill=\"\(color)\" stroke=\"\(contrast)\" stroke-width=\"\(num(fontSize*0.12))\" "
                + "stroke-linejoin=\"round\" paint-order=\"stroke\">\(Int(deg.rounded()))°</text>\n"
        }
        return out
    }

    private static func image(_ png: Data, _ frame: CGRect, pixelated: Bool) -> String {
        let href = "data:image/png;base64,\(png.base64EncodedString())"
        let style = pixelated ? " style=\"image-rendering:pixelated\"" : ""
        return "<image x=\"\(num(frame.minX))\" y=\"\(num(frame.minY))\" "
            + "width=\"\(num(frame.width))\" height=\"\(num(frame.height))\"\(style) "
            + "xlink:href=\"\(href)\" href=\"\(href)\"/>\n"
    }

    /// Render a pixelate region to a small blocky PNG to embed.
    private static func pixelatePNG(_ o: MarkupObject, base: NSImage?, baseFrame: CGRect) -> Data? {
        guard let base, o.frame.width > 1, o.frame.height > 1 else { return nil }
        let src = CGRect(x: o.frame.minX - baseFrame.minX,
                         y: base.size.height - (o.frame.maxY - baseFrame.minY),
                         width: o.frame.width, height: o.frame.height)
        let block: CGFloat = 9
        let small = NSSize(width: max((o.frame.width / block).rounded(), 2),
                           height: max((o.frame.height / block).rounded(), 2))
        let tiny = NSImage(size: small)
        tiny.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: small), from: src, operation: .copy, fraction: 1)
        tiny.unlockFocus()
        return tiny.pngData()
    }

    // MARK: Formatting

    private static func num(_ v: CGFloat) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(Double(r))
    }
    private static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
