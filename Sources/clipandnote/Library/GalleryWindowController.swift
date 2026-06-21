import AppKit
import UniformTypeIdentifiers

/// The in-app scrollback gallery: every markup in the library as a searchable
/// thumbnail grid. Double-click opens (copies + opens); right-click for
/// pin / delete / export.
final class GalleryWindowController: NSWindowController, NSCollectionViewDataSource {
    /// Open an entry (the app copies its PNG and opens the .can).
    var onOpen: ((UUID) -> Void)?

    private var collectionView: GalleryCollectionView!
    private var shown: [MarkupLibrary.Entry] = []
    private var filter = ""

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Markup Library"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        build()
        MarkupLibrary.shared.onChangeAlso { [weak self] in self?.reload() }
    }

    private func build() {
        let search = NSSearchField()
        search.placeholderString = "Search by name"
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 200, height: 168)
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12

        let cv = GalleryCollectionView()
        cv.collectionViewLayout = layout
        cv.dataSource = self
        cv.isSelectable = true
        cv.register(GalleryItem.self, forItemWithIdentifier: GalleryItem.id)
        cv.backgroundColors = [.clear]
        cv.owner = self
        collectionView = cv

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        cv.addGestureRecognizer(doubleClick)

        let container = NSView()
        container.addSubview(search)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window?.contentView = container
        reload()
    }

    func reload() {
        let all = MarkupLibrary.shared.recent(.max)
        shown = filter.isEmpty ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        collectionView?.reloadData()
    }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        filter = sender.stringValue
        reload()
    }

    @objc private func handleDoubleClick(_ g: NSClickGestureRecognizer) {
        let p = g.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: p) {
            onOpen?(shown[indexPath.item].id)
        }
    }

    func entry(at index: Int) -> MarkupLibrary.Entry? {
        index < shown.count ? shown[index] : nil
    }

    // MARK: Item actions (from the context menu)

    func open(_ id: UUID) { onOpen?(id) }
    func togglePin(_ id: UUID) {
        let pinned = MarkupLibrary.shared.entries.first { $0.id == id }?.pinned ?? false
        MarkupLibrary.shared.setPinned(id, !pinned)
    }
    func delete(_ id: UUID) { MarkupLibrary.shared.delete(id) }
    func export(_ id: UUID, ext: String, type: UTType) {
        guard let doc = MarkupLibrary.shared.document(id),
              let name = MarkupLibrary.shared.entries.first(where: { $0.id == id })?.name else { return }
        let data: Data?
        switch ext {
        case "pdf": data = MarkupExporter.pdf(doc)
        case "svg": data = SVGExporter.svg(doc).data(using: .utf8)
        default:    data = MarkupExporter.png(doc)
        }
        guard let data else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(name).\(ext)"
        panel.beginSheetModal(for: window!) { resp in
            if resp == .OK, let url = panel.url { try? data.write(to: url) }
        }
    }

    // MARK: Data source

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: GalleryItem.id, for: indexPath) as! GalleryItem
        let entry = shown[indexPath.item]
        item.configure(name: entry.name, pinned: entry.pinned,
                       thumbnail: MarkupLibrary.shared.thumbnail(entry.id))
        return item
    }
}

private extension MarkupLibrary {
    /// Chain a second observer without clobbering the existing one.
    func onChangeAlso(_ block: @escaping () -> Void) {
        let previous = onChange
        onChange = { previous?(); block() }
    }
}

/// NSCollectionView subclass that vends a per-item right-click menu.
final class GalleryCollectionView: NSCollectionView {
    weak var owner: GalleryWindowController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: p),
              let entry = owner?.entry(at: indexPath.item) else { return nil }
        let id = entry.id
        let menu = NSMenu()
        add(menu, "Open", { self.owner?.open(id) })
        menu.addItem(.separator())
        add(menu, entry.pinned ? "Unpin" : "Pin", { self.owner?.togglePin(id) })
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        add(exportMenu, "PNG…", { self.owner?.export(id, ext: "png", type: .png) })
        add(exportMenu, "PDF…", { self.owner?.export(id, ext: "pdf", type: .pdf) })
        add(exportMenu, "SVG…", { self.owner?.export(id, ext: "svg", type: .svg) })
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        menu.addItem(.separator())
        add(menu, "Delete", { self.owner?.delete(id) })
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(BlockMenuItem.run(_:)), keyEquivalent: "")
        let block = BlockMenuItem(action)
        item.target = block
        item.representedObject = block   // retain it
        menu.addItem(item)
    }
}

/// Tiny helper so menu items can carry a closure.
final class BlockMenuItem: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run(_ sender: Any?) { block() }
}
