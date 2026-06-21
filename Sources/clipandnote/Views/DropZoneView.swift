import AppKit

/// The empty-state area of a blank editor: a dashed drop zone that accepts a
/// dragged image or `.can` file. Hosts the Open / Capture buttons (added by the
/// editor) and highlights while a drag hovers.
final class DropZoneView: NSView {
    var onImage: ((NSImage) -> Void)?
    var onCanURL: ((URL) -> Void)?

    private var highlighted = false { didSet { needsDisplay = true } }
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "gif", "bmp"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let card = bounds.insetBy(dx: 28, dy: 28)
        let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    // MARK: Dragging

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            if let can = urls.first(where: { $0.pathExtension.lowercased() == "can" }) {
                onCanURL?(can); return true
            }
            if let image = urls.first(where: { Self.imageExts.contains($0.pathExtension.lowercased()) })
                .flatMap({ NSImage(contentsOf: $0) }) {
                onImage?(image); return true
            }
        }
        if let image = NSImage(pasteboard: pb) { onImage?(image); return true }
        return false
    }
}
