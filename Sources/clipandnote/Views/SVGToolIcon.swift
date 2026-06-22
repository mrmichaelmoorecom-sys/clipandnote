import AppKit

/// Renders one of the SVGs in `Resources/toolicons/` into an `NSImage`, with
/// `currentColor` substituted to the requested fill — and, optionally, drawn
/// twice (a wider darkened outline pass underneath, the colored fill on top)
/// so tools that produce a colored mark on the canvas show that same color in
/// the toolbar. Output of the tool == the icon of the tool.
enum SVGToolIcon {

    /// Render the tool icon at the given point size. `fill` is the visible color
    /// (use `.labelColor` for monochrome tools); `outline` darkens a wider
    /// underlay so a chosen color still reads against the toolbar background.
    static func render(_ name: String, fill: NSColor, outline: NSColor?, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg",
                                        subdirectory: "toolicons"),
              let svgText = try? String(contentsOf: url) else { return nil }
        let fillHex = fill.toolboxHexString

        let pixel = Int(size * 2)   // @2x bitmap so the icon stays sharp on Retina
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: pixel, pixelsHigh: pixel, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: pixel * 4, bitsPerPixel: 32) else { return nil }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let frame = NSRect(x: 0, y: 0, width: size, height: size)

        if let outline {
            let outlineHex = outline.toolboxHexString
            // Outline pass: same SVG, currentColor → outline color, every
            // stroke-width bumped just enough to peek around the colored core.
            // A small bump (≈1.2) keeps the colored fill dominant at icon size,
            // matching how a marker's stroke reads vs. a thin contour around it.
            let outlineSvg = withCurrentColor(svgText, outlineHex)
                .replacingMatches(of: #"stroke-width="(\d+(?:\.\d+)?)""#) { match in
                    let w = Double(match) ?? 0
                    return "stroke-width=\"\(w + 1.2)\""
                }
            if let data = outlineSvg.data(using: .utf8), let img = NSImage(data: data) {
                img.draw(in: frame)
            }
        }

        let fillSvg = withCurrentColor(svgText, fillHex)
        if let data = fillSvg.data(using: .utf8), let img = NSImage(data: data) {
            img.draw(in: frame)
        }

        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: size, height: size))
        out.addRepresentation(rep)
        return out
    }

    /// Substitute `currentColor` everywhere with an explicit hex string. Also
    /// set the SVG root `color=` so any element inheriting picks it up.
    private static func withCurrentColor(_ svg: String, _ hex: String) -> String {
        svg.replacingOccurrences(of: "currentColor", with: hex)
    }
}

private extension NSColor {
    /// Lossy sRGB hex. The icon renderer needs a literal string in the SVG.
    var toolboxHexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent   * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private extension String {
    /// Replace each regex match using a transform of the *first* capture group.
    func replacingMatches(of pattern: String, _ transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        let ns = self as NSString
        let matches = re.matches(in: self, range: NSRange(location: 0, length: ns.length))
        var result = self
        for m in matches.reversed() {
            guard m.numberOfRanges >= 2 else { continue }
            let cap = ns.substring(with: m.range(at: 1))
            let full = ns.substring(with: m.range(at: 0))
            let _ = full   // unused; kept for clarity
            let replacement = transform(cap)
            let r = m.range
            result = (result as NSString).replacingCharacters(in: r, with: replacement)
        }
        return result
    }
}
