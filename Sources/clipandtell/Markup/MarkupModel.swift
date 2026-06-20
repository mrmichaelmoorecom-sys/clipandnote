import AppKit

/// An sRGB color that round-trips through Codable, so it can live in the `.ctell`
/// document format. AppKit's NSColor isn't directly Codable in a stable way.
struct RGBAColor: Codable, Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let red = RGBAColor(r: 0.93, g: 0.20, b: 0.18, a: 1)
    static let highlighter = RGBAColor(r: 1.0, g: 0.86, b: 0.18, a: 0.38)
}

/// The kinds of object that can live on the canvas. Each is an independent,
/// selectable, movable layer — including pasted images, which is the core fix
/// over Skitch (paste *adds* an object instead of replacing your work).
enum MarkupKind: String, Codable {
    case arrow, line, rectangle, ellipse, freehand, text, highlighter, pixelate, image
}

/// A single markup object. A deliberately flat, fully-Codable struct: a few
/// fields go unused per kind, but it keeps the document format trivial and the
/// renderer simple. Geometry lives in canvas points (1:1 with the base image).
struct MarkupObject: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: MarkupKind

    /// Bounding box for frame-based kinds (rect, ellipse, text, highlighter,
    /// pixelate, image). For line/arrow/freehand it is the derived bounds.
    var frame: CGRect
    /// Endpoints / path for line, arrow (2 points) and freehand (many points).
    var points: [CGPoint]

    var stroke: RGBAColor
    var fill: RGBAColor?
    var lineWidth: CGFloat

    var text: String
    var fontSize: CGFloat

    /// PNG bytes for `.image` objects (pasted or dropped images).
    var imageData: Data?

    init(kind: MarkupKind,
         id: UUID = UUID(),
         frame: CGRect = .zero,
         points: [CGPoint] = [],
         stroke: RGBAColor = .red,
         fill: RGBAColor? = nil,
         lineWidth: CGFloat = 4,
         text: String = "",
         fontSize: CGFloat = 28,
         imageData: Data? = nil) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.points = points
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
        self.imageData = imageData
    }

    /// Recompute `frame` from `points` for path-based kinds, so selection and
    /// hit-testing have a bounding box to work with.
    mutating func recomputeBounds() {
        guard !points.isEmpty else { return }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let pad = max(lineWidth, 8)
        frame = CGRect(x: minX - pad, y: minY - pad,
                       width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
    }

    var isPathBased: Bool { kind == .line || kind == .arrow || kind == .freehand }

    /// Translate the whole object by a delta.
    mutating func move(by d: CGSize) {
        frame = frame.offsetBy(dx: d.width, dy: d.height)
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }
}

/// A markup document: an optional base image plus an ordered list of objects
/// (array order is z-order, back to front). This is the in-memory shape that the
/// `.ctell` format (Phase 3) will serialize.
struct MarkupDocument {
    var baseImage: NSImage?
    var objects: [MarkupObject] = []
    /// Canvas size in points — the base image's point size, or a default.
    var canvasSize: CGSize
}
