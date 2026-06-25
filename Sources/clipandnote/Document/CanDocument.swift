import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// The `.can` document type (resolves to com.clipandnote.can once the app's
    /// Info.plist type declaration is registered; a dynamic type otherwise).
    static var canDocument: UTType { UTType(filenameExtension: "can") ?? .data }
}

/// One page of a `.can` document — the canvas geometry, base snapshot, and
/// vector object graph for a single markup canvas. Multi-page documents (an
/// opened PDF) carry these in `CanDocument.extraPages`; page 1 lives in the
/// flat fields of `CanDocument` so single-page files stay readable.
struct CanPage: Codable {
    var canvasSize: CGSize
    var baseImageFrame: CGRect
    var baseImagePNG: Data?
    var objects: [MarkupObject]
    var backgroundColor: RGBAColor?

    init(_ doc: MarkupDocument) {
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

/// The `.can` file — clipandnote's portable markup document. A single JSON file
/// holding the canvas geometry, the base snapshot, and the vector object graph,
/// so it stays editable (objects + layers) and is inspectable/parseable by any
/// tool. The base image and pasted-image objects are embedded as base64 PNG.
///
/// Multi-page documents (e.g. an opened PDF) keep page 1 in the flat fields and
/// pages 2…n in `extraPages`, so a single-page file is unchanged and still
/// decodes the same way.
struct CanDocument: Codable {
    var version: Int
    var canvasSize: CGSize
    var baseImageFrame: CGRect
    var baseImagePNG: Data?
    var objects: [MarkupObject]
    /// Optional for back-compat with v1 files (which had no background); nil = white.
    var backgroundColor: RGBAColor?
    /// Pages beyond the first; nil/empty = a single-page document.
    var extraPages: [CanPage]?

    init(_ doc: MarkupDocument) {
        version = 1
        canvasSize = doc.canvasSize
        baseImageFrame = doc.baseImageFrame
        baseImagePNG = doc.baseImage?.pngData()
        objects = doc.objects
        backgroundColor = doc.backgroundColor
        extraPages = nil
    }

    init(pages: [MarkupDocument]) {
        let first = pages.first ?? MarkupDocument(baseImage: nil,
                                                  canvasSize: CGSize(width: 720, height: 560))
        self.init(first)
        if pages.count > 1 {
            version = 2
            extraPages = pages.dropFirst().map(CanPage.init)
        }
    }

    var markupDocument: MarkupDocument {
        MarkupDocument(baseImage: baseImagePNG.flatMap { NSImage(data: $0) },
                       objects: objects, canvasSize: canvasSize, baseImageFrame: baseImageFrame,
                       backgroundColor: backgroundColor ?? .white)
    }

    /// Every page in order — page 1 (the flat fields) followed by `extraPages`.
    var allPages: [MarkupDocument] {
        [markupDocument] + (extraPages?.map { $0.markupDocument } ?? [])
    }
}

/// Read/write `.can` files.
enum CanFile {
    static let ext = "can"
    static let uti = "com.clipandnote.can"

    static func write(_ doc: MarkupDocument, to url: URL) throws {
        try encode(CanDocument(doc), to: url)
    }

    /// Write a multi-page document (page 1 + extras).
    static func write(pages: [MarkupDocument], to url: URL) throws {
        try encode(CanDocument(pages: pages), to: url)
    }

    private static func encode(_ doc: CanDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(doc).write(to: url, options: .atomic)
    }

    /// Page 1 of the document (for single-page callers and thumbnails).
    static func read(_ url: URL) throws -> MarkupDocument {
        try JSONDecoder().decode(CanDocument.self, from: Data(contentsOf: url)).markupDocument
    }

    /// Every page of the document, in order.
    static func readPages(_ url: URL) throws -> [MarkupDocument] {
        try JSONDecoder().decode(CanDocument.self, from: Data(contentsOf: url)).allPages
    }
}
