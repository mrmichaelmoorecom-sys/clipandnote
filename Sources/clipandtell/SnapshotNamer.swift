import AppKit
import Vision

/// Names a snapshot with a timestamp plus a short, contextual label — generated
/// fully on-device by reading the most prominent text in the image with Vision
/// OCR (the project is on-device-only). Falls back to "Snapshot".
enum SnapshotNamer {

    /// Filename-safe timestamp, e.g. "2026-06-20 11-30".
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.string(from: date)
    }

    /// OCR the image off the main thread; call back on the main thread with a
    /// short name (≤ ~32 chars).
    static func contextualName(for image: NSImage, completion: @escaping (String) -> Void) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            DispatchQueue.main.async { completion("Snapshot") }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            let name = bestName(from: request.results ?? [])
            DispatchQueue.main.async { completion(name) }
        }
    }

    /// Pick the most prominent line: rank by text height (a heading is large),
    /// with a slight bias toward text near the top.
    private static func bestName(from observations: [VNRecognizedTextObservation]) -> String {
        let scored: [(text: String, score: CGFloat)] = observations.compactMap { o in
            guard let top = o.topCandidates(1).first, top.confidence > 0.3 else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            return (text, o.boundingBox.height + o.boundingBox.maxY * 0.15)
        }
        guard let best = scored.max(by: { $0.score < $1.score })?.text else { return "Snapshot" }
        return clean(best)
    }

    private static func clean(_ s: String) -> String {
        let collapsed = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if collapsed.count > 32 {
            return String(collapsed.prefix(32)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return collapsed.isEmpty ? "Snapshot" : collapsed
    }
}
