import AppKit

extension NSImage {
    /// PNG encoding at the image's natural pixel resolution.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Pixel dimensions (not points), useful for display labels.
    var pixelSize: NSSize? {
        guard let rep = representations.first as? NSBitmapImageRep else { return size }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
