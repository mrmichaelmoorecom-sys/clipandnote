import AppKit

/// Renders a markup document to shareable formats. PNG and PDF reuse
/// `MarkupRenderer`, so exports look exactly like the canvas.
enum MarkupExporter {

    /// Draw the document into the *current* flipped (top-left) graphics context.
    static func draw(_ doc: MarkupDocument) {
        NSColor.white.setFill()
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
    static func pdf(_ doc: MarkupDocument) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: doc.canvasSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        // PDF is bottom-left origin; flip the CTM to top-left (as NSImage(flipped:)
        // does) so MarkupRenderer's top-left drawing comes out upright.
        ctx.translateBy(x: 0, y: doc.canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(doc)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
