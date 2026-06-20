import AppKit
import NaturalLanguage
import Vision

/// Names a snapshot with a timestamp plus a short, contextual label — generated
/// fully on-device. Combines OCR of the most prominent text (refined with Natural
/// Language) with a visual content label from `VisualClassifier` (MobileCLIP when
/// its model is present, else Vision). Text wins when the capture is text-heavy;
/// the visual label carries image-heavy captures that OCR can't describe.
enum SnapshotNamer {
    private static let classifier: VisualClassifier = VisualClassifierFactory.make()

    /// Filename-safe timestamp, e.g. "2026-06-20 11-30".
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.string(from: date)
    }

    /// Compute a name off the main thread; call back on the main thread.
    static func contextualName(for image: NSImage, completion: @escaping (String) -> Void) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            DispatchQueue.main.async { completion("Snapshot") }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ocr = ocrName(cg)
            let visual = classifier.classify(cg).first
            let name = compose(ocr: ocr, visual: visual)
            DispatchQueue.main.async { completion(name) }
        }
    }

    /// Text-heavy captures keep their OCR heading; otherwise fall back to the
    /// visual label (e.g. "Chart", "Map", "Photo") so image-only shots still read.
    private static func compose(ocr: String?, visual: VisualLabel?) -> String {
        if let ocr { return ocr }
        if let visual, visual.score > 0.25 { return visual.text }
        return "Snapshot"
    }

    // MARK: OCR

    private static func ocrName(_ cg: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])

        // Rank by text height (a heading is large), slight bias toward the top.
        let scored: [(text: String, score: CGFloat)] = (request.results ?? []).compactMap { o in
            guard let top = o.topCandidates(1).first, top.confidence > 0.3 else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            return (text, o.boundingBox.height + o.boundingBox.maxY * 0.15)
        }
        guard let best = scored.max(by: { $0.score < $1.score })?.text else { return nil }
        return clean(refine(best))
    }

    /// For long lines, keep the leading meaningful words (nouns / names / numbers)
    /// so the label stays tight instead of trailing into a whole sentence.
    private static func refine(_ text: String) -> String {
        guard text.split(separator: " ").count > 5 else { return text }
        let keep: Set<NLTag> = [.noun, .otherWord, .number, .adjective, .verb]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var words: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, keep.contains(tag) { words.append(String(text[range])) }
            return words.count < 6
        }
        return words.isEmpty ? text : words.joined(separator: " ")
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
