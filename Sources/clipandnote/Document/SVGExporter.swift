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
        case .highlighter:
            let fill = o.fill ?? .highlighter
            return "<rect x=\"\(num(o.frame.minX))\" y=\"\(num(o.frame.minY))\" "
                + "width=\"\(num(o.frame.width))\" height=\"\(num(o.frame.height))\" "
                + "fill=\"\(hex(fill.nsColor))\" fill-opacity=\"\(num(fill.a))\" "
                + "style=\"mix-blend-mode:multiply\"/>\n"
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
        let color = hex(o.stroke.nsColor), contrast = hex(MarkupRenderer.contrastColor(for: o.stroke.nsColor))
        let x = num(o.frame.minX)
        let lines = o.text.components(separatedBy: "\n")
        let tspans = lines.enumerated().map { i, line in
            "<tspan x=\"\(x)\" dy=\"\(i == 0 ? "0" : num(o.fontSize * 1.2))\">\(escape(line))</tspan>"
        }.joined()
        // A soft contrast halo (blurred drop shadow, no offset) keeps the label
        // legible on any background while reading as clean text — matching the
        // canvas's NSShadow halo rather than a hard glyph outline.
        let fid = "halo-\(o.id.uuidString.prefix(8))"
        let filter = "<filter id=\"\(fid)\" x=\"-30%\" y=\"-30%\" width=\"160%\" height=\"160%\">"
            + "<feDropShadow dx=\"0\" dy=\"0\" stdDeviation=\"1.6\" flood-color=\"\(contrast)\" flood-opacity=\"0.8\"/></filter>"
        return filter
            + "<text x=\"\(x)\" y=\"\(num(o.frame.minY + o.fontSize * 0.82))\" "
            + "font-family=\"\(escape(family))\" font-size=\"\(num(o.fontSize))\" font-weight=\"600\" "
            + "fill=\"\(color)\" filter=\"url(#\(fid))\">\(tspans)</text>\n"
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
