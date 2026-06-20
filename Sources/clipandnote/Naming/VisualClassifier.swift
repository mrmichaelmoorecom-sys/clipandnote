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
    private let vnModel: VNCoreMLModel
    private let labels: [String]
    private let embeddings: [[Float]]   // each L2-normalized
    /// CLIP temperature — sharpens cosine sims into usable probabilities.
    private let logitScale: Float

    private struct Pack: Decodable {
        let labels: [String]
        let embeddings: [[Float]]
        let logitScale: Float?
    }

    init?() {
        guard let modelURL = Bundle.main.url(forResource: "MobileCLIPImage", withExtension: "mlmodelc"),
              let packURL = Bundle.main.url(forResource: "clip_labels", withExtension: "json"),
              let model = try? MLModel(contentsOf: modelURL),
              let vn = try? VNCoreMLModel(for: model),
              let data = try? Data(contentsOf: packURL),
              let pack = try? JSONDecoder().decode(Pack.self, from: data)
        else { return nil }
        self.vnModel = vn
        self.labels = pack.labels
        self.embeddings = pack.embeddings.map { Self.normalized($0) }
        self.logitScale = pack.logitScale ?? 100
    }

    func classify(_ cgImage: CGImage) -> [VisualLabel] {
        // Vision handles resize + the model's baked normalization correctly —
        // no hand-rolled pixel buffer (and its channel-order pitfalls).
        let request = VNCoreMLRequest(model: vnModel)
        // Match the model's training preprocess (resize shortest side + center
        // crop); stretching to a square gives out-of-distribution embeddings.
        request.imageCropAndScaleOption = .centerCrop
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        guard let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
              let vector = obs.featureValue.multiArrayValue else { return [] }

        let embedding = Self.normalized((0..<vector.count).map { vector[$0].floatValue })
        let cosines = embeddings.map { Self.dot(embedding, $0) }
        let probs = Self.softmax(cosines.map { $0 * logitScale })
        return zip(labels, probs)
            .map { VisualLabel(text: $0.0, score: $0.1) }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { $0 }
    }

    // MARK: helpers

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm.isFinite && norm > 0 ? v.map { $0 / norm } : v
    }
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
    private static func softmax(_ v: [Float]) -> [Float] {
        let m = v.max() ?? 0
        let exps = v.map { exp($0 - m) }
        let sum = exps.reduce(0, +)
        return sum > 0 ? exps.map { $0 / sum } : exps
    }
}
