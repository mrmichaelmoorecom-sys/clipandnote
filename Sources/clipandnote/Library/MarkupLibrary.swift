import AppKit

/// clipandnote's local markup library — its "cue". Every capture autosaves here
/// as a `.can` (editable source) plus a `.png` (flattened preview), capped by a
/// retention limit (pinned items are never evicted). Mirrors clipandcue's rolling
/// history. Lives in ~/Library/Application Support/clipandnote/.
final class MarkupLibrary {
    static let shared = MarkupLibrary()

    struct Entry: Codable, Identifiable {
        let id: UUID
        var createdAt: Date
        var name: String
        var pinned: Bool
        var width: Int
        var height: Int
    }

    /// All entries, newest-created first.
    private(set) var entries: [Entry] = []
    /// Fired whenever the library changes, so the menu/gallery can refresh.
    var onChange: (() -> Void)?

    private let fm = FileManager.default
    private let libraryDir: URL
    private let indexURL: URL
    private var thumbCache: [UUID: NSImage] = [:]

    private init() {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = appSupport.appendingPathComponent("clipandnote", isDirectory: true)
        libraryDir = root.appendingPathComponent("library", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        try? fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        loadIndex()
    }

    func canURL(_ id: UUID) -> URL { libraryDir.appendingPathComponent("\(id).can") }
    func pngURL(_ id: UUID) -> URL { libraryDir.appendingPathComponent("\(id).png") }

    // MARK: Mutations

    /// Create a new entry for a fresh capture and persist its first state.
    @discardableResult
    func add(_ doc: MarkupDocument, name: String, at date: Date) -> UUID {
        let id = UUID()
        entries.insert(Entry(id: id, createdAt: date, name: name, pinned: false,
                             width: Int(doc.canvasSize.width), height: Int(doc.canvasSize.height)),
                       at: 0)
        write(doc, id: id)
        enforceRetention()
        saveIndex()
        onChange?()
        return id
    }

    /// Autosave an existing entry's current state (and optionally rename it).
    func update(_ doc: MarkupDocument, id: UUID, name: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let name, !name.isEmpty { entries[i].name = name }
        entries[i].width = Int(doc.canvasSize.width)
        entries[i].height = Int(doc.canvasSize.height)
        write(doc, id: id)
        saveIndex()
        onChange?()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        try? fm.removeItem(at: canURL(id))
        try? fm.removeItem(at: pngURL(id))
        thumbCache[id] = nil
        saveIndex()
        onChange?()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pinned = pinned
        saveIndex()
        onChange?()
    }

    // MARK: Reads

    func document(_ id: UUID) -> MarkupDocument? { try? CanFile.read(canURL(id)) }
    func flatPNG(_ id: UUID) -> Data? { try? Data(contentsOf: pngURL(id)) }
    func thumbnail(_ id: UUID) -> NSImage? {
        if let cached = thumbCache[id] { return cached }
        let image = NSImage(contentsOf: pngURL(id))
        thumbCache[id] = image
        return image
    }

    /// Pinned first, then newest; capped at `n` — for the menu-bar recents.
    func recent(_ n: Int) -> [Entry] {
        entries.sorted { ($0.pinned ? 1 : 0, $0.createdAt) > ($1.pinned ? 1 : 0, $1.createdAt) }
            .prefix(n).map { $0 }
    }

    // MARK: Internals

    private func write(_ doc: MarkupDocument, id: UUID) {
        try? CanFile.write(doc, to: canURL(id))
        if let png = MarkupExporter.png(doc, scale: 1) {
            try? png.write(to: pngURL(id))
            thumbCache[id] = NSImage(data: png)
        }
    }

    /// Re-apply the retention limit now (e.g. after the user lowers it in
    /// Preferences). Pinned items are never evicted; persists the new index.
    func applyRetention() {
        enforceRetention()
        saveIndex()
    }

    private func enforceRetention() {
        let limit = max(AppSettings.shared.localHistoryLimit, 1)
        let evictable = entries.filter { !$0.pinned }.sorted { $0.createdAt > $1.createdAt }
        let evict = evictable.dropFirst(limit).map { $0.id }
        guard !evict.isEmpty else { return }
        for id in evict {
            try? fm.removeItem(at: canURL(id))
            try? fm.removeItem(at: pngURL(id))
            thumbCache[id] = nil
        }
        entries.removeAll { evict.contains($0.id) }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = list
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
