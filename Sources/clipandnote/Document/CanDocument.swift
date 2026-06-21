import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// The `.can` document type (resolves to com.clipandnote.can once the app's
    /// Info.plist type declaration is registered; a dynamic type otherwise).
    static var canDocument: UTType { UTType(filenameExtension: "can") ?? .data }
}

/// The `.can` file — clipandnote's portable markup document. A single JSON file
/// holding the canvas geometry, the base snapshot, and the vector object graph,
/// so it stays editable (objects + layers) and is inspectable/parseable by any
/// tool. The base image and pasted-image objects are embedded as base64 PNG.
struct CanDocument: Codable {
    var version: Int
    var canvasSize: CGSize
    var baseImageFrame: CGRect
    var baseImagePNG: Data?
    var objects: [MarkupObject]
    /// Optional for back-compat with v1 files (which had no background); nil = white.
    var backgroundColor: RGBAColor?

    init(_ doc: MarkupDocument) {
        version = 1
        canvasSize = doc.canvasSize
        baseImageFrame = doc.baseImageFrame
        baseImagePNG = doc.baseImage?.pngData()
        objects = doc.objects
        backgroundColor = doc.backgroundColor
    }

    var markupDocument: MarkupDocument {
        MarkupDocument(baseImage: baseImagePNG.flatMap { NSImage(data: $0) },
                       objects: objects, canvasSize: canvasSize, baseImageFrame: baseImageFrame,
                       backgroundColor: backgroundColor ?? .white)
    }
}

/// Read/write `.can` files.
enum CanFile {
    static let ext = "can"
    static let uti = "com.clipandnote.can"

    static func write(_ doc: MarkupDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(CanDocument(doc)).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> MarkupDocument {
        try JSONDecoder().decode(CanDocument.self, from: Data(contentsOf: url)).markupDocument
    }
}
