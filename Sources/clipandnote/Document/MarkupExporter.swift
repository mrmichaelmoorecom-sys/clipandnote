import AppKit

/// Renders a markup document to shareable formats. PNG and PDF reuse
/// `MarkupRenderer`, so exports look exactly like the canvas.
enum MarkupExporter {

    /// Draw the document into the *current* flipped (top-left) graphics context.
    static func draw(_ doc: MarkupDocument) {
        doc.backgroundColor.nsColor.setFill()
        NSRect(origin: .zero, size: doc.canvasSize).fill()
        doc.baseImage?.draw(in: doc.baseImageFrame)
        for object in doc.objects {
            MarkupRenderer.draw(object, baseImage: doc.baseImage, baseFrame: doc.baseImageFrame)
        }
    }

    /// High-resolution flattened PNG (`scale` × the canvas point size, so Retina
    /// captures export at native pixels).
    static func png(_ doc: MarkupDocument, scale: CGFloat = 2) -> Data? {
        let image = NSImage(size: doc.canvasSize, flipped: true) { _ in draw(doc); return true }
        let w = Int(doc.canvasSize.width * scale), h = Int(doc.canvasSize.height * scale)
        guard w > 0, h > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = doc.canvasSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: doc.canvasSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Vector PDF — shapes, arrows, and text stay vector (text is selectable);
    /// only the base snapshot and pasted images are embedded as raster.
    static func pdf(_ doc: MarkupDocument) -> Data? { multiPagePDF([doc]) }

    /// One PDF with a page per document (each at its own size). Used by Export
    /// All. When `paginate` is true, a "N / total" page number is stamped in
    /// the bottom-center of every page.
    static func multiPagePDF(_ docs: [MarkupDocument], paginate: Bool = false) -> Data? {
        guard !docs.isEmpty else { return nil }
        let data = NSMutableData()
        var firstBox = CGRect(origin: .zero, size: docs[0].canvasSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return nil }
        for (i, doc) in docs.enumerated() {
            var box = CGRect(origin: .zero, size: doc.canvasSize)
            let pageInfo = [kCGPDFContextMediaBox as String:
                                Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.saveGState()
            // PDF is bottom-left origin; flip the CTM to top-left (as
            // NSImage(flipped:) does) so top-left drawing comes out upright.
            ctx.translateBy(x: 0, y: doc.canvasSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            draw(doc)
            if paginate { drawPageNumber(i + 1, of: docs.count, on: doc.canvasSize) }
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Stamp "page / total" centered along the bottom edge, on a translucent
    /// white pill so it reads on any page colour. Drawn in the flipped
    /// (top-left origin) context, so larger y = lower on the page.
    private static func drawPageNumber(_ page: Int, of total: Int, on size: CGSize) {
        let text = "\(page) / \(total)" as NSString
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textSize = text.size(withAttributes: [.font: font])
        let padX: CGFloat = 8, padY: CGFloat = 3
        let pillW = textSize.width + padX * 2, pillH = textSize.height + padY * 2
        let pillX = (size.width - pillW) / 2
        let pillY = size.height - pillH - 12      // 12pt up from the bottom
        let pill = NSBezierPath(roundedRect: NSRect(x: pillX, y: pillY, width: pillW, height: pillH),
                                xRadius: pillH / 2, yRadius: pillH / 2)
        NSColor.white.withAlphaComponent(0.85).setFill(); pill.fill()
        NSColor.separatorColor.setStroke(); pill.lineWidth = 0.5; pill.stroke()
        text.draw(at: CGPoint(x: pillX + padX, y: pillY + padY),
                  withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.75)])
    }
}
