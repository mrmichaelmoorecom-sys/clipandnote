import AppKit
import CoreML
import Vision

/// A short, human-readable label for the visual content of a capture, with a
/// confidence in 0…1.
struct VisualLabel { let text: String; let score: Float }

/// Classifies the *visual* content of an image (independent of any text in it).
protocol VisualClassifier {
    func classify(_ cgImage: CGImage) -> [VisualLabel]
}

/// Picks the best available classifier: MobileCLIP if its model has been added to
/// the bundle (preferred — a screenshot-tuned vocabulary), otherwise Vision's
/// built-in scene classifier so naming still beats plain OCR out of the box.
enum VisualClassifierFactory {
    static func make() -> VisualClassifier {
        MobileCLIPClassifier() ?? VisionClassifier()
    }
}

// MARK: - Vision fallback (always available, no bundled model)

/// Uses Vision's on-device `VNClassifyImageRequest`. Maps a few noisy taxonomy
/// identifiers to friendlier words; otherwise prettifies the raw identifier.
final class VisionClassifier: VisualClassifier {
    private static let friendly: [String: String] = [
        "document": "Document", "screenshot": "Screenshot", "text": "Document",
        "website": "Web page", "web_site": "Web page", "monitor": "Screen",
        "chart": "Chart", "graph": "Chart", "diagram": "Diagram",
        "map": "Map", "photograph": "Photo", "people": "People",
        "menu": "Menu", "form": "Form", "code": "Code",
    ]

    func classify(_ cgImage: CGImage) -> [VisualLabel] {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let results = (request.results ?? [])
            .filter { $0.confidence > 0.2 }
            .prefix(3)
        return results.map { obs in
            let key = obs.identifier.lowercased()
            let pretty = Self.friendly[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            return VisualLabel(text: pretty, score: obs.confidence)
        }
    }
}

// MARK: - MobileCLIP (bundled model — preferred when present)

/// Zero-shot classification with a bundled MobileCLIP image encoder against a
/// precomputed set of label embeddings (see scripts/export_mobileclip.py).
/// `init?` returns nil when the model hasn't been added yet, so the app falls
/// back to `VisionClassifier`.
final class MobileCLIPClassifier: VisualClassifier {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let inputSize: Int
    private let labels: [String]
    private let embeddings: [[Float]]   // each L2-normalized

    private struct Pack: Decodable {
        let inputName: String
        let outputName: String
        let inputSize: Int
        let labels: [String]
        let embeddings: [[Float]]
    }

    init?() {
        guard let modelURL = Bundle.main.url(forResource: "MobileCLIPImage", withExtension: "mlmodelc"),
              let packURL = Bundle.main.url(forResource: "clip_labels", withExtension: "json"),
              let model = try? MLModel(contentsOf: modelURL),
              let data = try? Data(contentsOf: packURL),
              let pack = try? JSONDecoder().decode(Pack.self, from: data)
        else { return nil }
        self.model = model
        self.inputName = pack.inputName
        self.outputName = pack.outputName
        self.inputSize = pack.inputSize
        self.labels = pack.labels
        self.embeddings = pack.embeddings.map { Self.normalized($0) }
    }

    func classify(_ cgImage: CGImage) -> [VisualLabel] {
        guard let pixels = Self.pixelBuffer(from: cgImage, size: inputSize),
              let provider = try? MLDictionaryFeatureProvider(
                  dictionary: [inputName: MLFeatureValue(pixelBuffer: pixels)]),
              let out = try? model.prediction(from: provider),
              let vector = out.featureValue(for: outputName)?.multiArrayValue
        else { return [] }

        let embedding = Self.normalized((0..<vector.count).map { vector[$0].floatValue })
        let scored = zip(labels, embeddings)
            .map { VisualLabel(text: $0.0, score: Self.dot(embedding, $0.1)) }
            .sorted { $0.score > $1.score }
        return Array(scored.prefix(3))
    }

    // MARK: helpers

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Resize to a square `size`×`size` BGRA pixel buffer for the CoreML model.
    /// (Normalization is baked into the exported model — see the script.)
    private static func pixelBuffer(from cgImage: CGImage, size: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }
}
