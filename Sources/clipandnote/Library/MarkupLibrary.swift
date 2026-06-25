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
        /// Number of pages in the backing `.can` (1 for a normal capture; >1 for
        /// an opened multi-page PDF). Width/height describe page 1.
        var pageCount: Int

        init(id: UUID, createdAt: Date, name: String, pinned: Bool,
             width: Int, height: Int, pageCount: Int = 1) {
            self.id = id; self.createdAt = createdAt; self.name = name
            self.pinned = pinned; self.width = width; self.height = height
            self.pageCount = pageCount
        }

        // Custom decode so index.json files written before `pageCount` existed
        // still load (missing key → single page) instead of failing the whole index.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            name = try c.decode(String.self, forKey: .name)
            pinned = try c.decode(Bool.self, forKey: .pinned)
            width = try c.decode(Int.self, forKey: .width)
            height = try c.decode(Int.self, forKey: .height)
            pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1
        }
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
        entries[i].pageCount = 1
        write(doc, id: id)
        saveIndex()
        onChange?()
    }

    /// Create a multi-page entry (e.g. an opened PDF) and persist all pages.
    @discardableResult
    func add(pages: [MarkupDocument], name: String, at date: Date) -> UUID {
        let id = UUID()
        let first = pages.first ?? MarkupDocument(baseImage: nil,
                                                  canvasSize: CGSize(width: 720, height: 560))
        entries.insert(Entry(id: id, createdAt: date, name: name, pinned: false,
                             width: Int(first.canvasSize.width), height: Int(first.canvasSize.height),
                             pageCount: max(pages.count, 1)),
                       at: 0)
        write(pages: pages, id: id)
        enforceRetention()
        saveIndex()
        onChange?()
        return id
    }

    /// Autosave an existing multi-page entry's current state.
    func update(pages: [MarkupDocument], id: UUID, name: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let name, !name.isEmpty { entries[i].name = name }
        if let first = pages.first {
            entries[i].width = Int(first.canvasSize.width)
            entries[i].height = Int(first.canvasSize.height)
        }
        entries[i].pageCount = max(pages.count, 1)
        write(pages: pages, id: id)
        saveIndex()
        onChange?()
    }

    /// Rename an entry without rewriting its document (cheap; safe for
    /// multi-page entries, which a full `update` would otherwise need all pages for).
    func rename(_ id: UUID, _ name: String) {
        guard !name.isEmpty, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].name = name
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
    /// Every page of an entry (one element for a normal single-page capture).
    func pages(_ id: UUID) -> [MarkupDocument]? { try? CanFile.readPages(canURL(id)) }
    func flatPNG(_ id: UUID) -> Data? { try? Data(contentsOf: pngURL(id)) }
    func thumbnail(_ id: UUID) -> NSImage? {
        if let cached = thumbCache[id] { return cached }
        let image = NSImage(contentsOf: pngURL(id))
        thumbCache[id] = image
        return image
    }

    /// The menu-bar recents in their stored order, capped at `n`. New captures
    /// land on top (`add` inserts at 0); the user can drag-reorder via
    /// `moveRecent`, and that order is what export follows. Pinning no longer
    /// floats items here — it only protects them from retention eviction.
    func recent(_ n: Int) -> [Entry] { Array(entries.prefix(n)) }

    /// Drag-reorder a recent. `from`/`to` are row indices in the displayed
    /// (= stored) order; persists the new order so it survives relaunch.
    func moveRecent(from: Int, to: Int) {
        guard entries.indices.contains(from), from != to else { return }
        let e = entries.remove(at: from)
        let dest = from < to ? to - 1 : to
        entries.insert(e, at: min(max(dest, 0), entries.count))
        saveIndex()
        onChange?()
    }

    // MARK: Internals

    private func write(_ doc: MarkupDocument, id: UUID) {
        try? CanFile.write(doc, to: canURL(id))
        writeThumbnail(doc, id: id)
    }

    private func write(pages: [MarkupDocument], id: UUID) {
        try? CanFile.write(pages: pages, to: canURL(id))
        if let first = pages.first { writeThumbnail(first, id: id) }   // page 1 = the preview
    }

    private func writeThumbnail(_ doc: MarkupDocument, id: UUID) {
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
