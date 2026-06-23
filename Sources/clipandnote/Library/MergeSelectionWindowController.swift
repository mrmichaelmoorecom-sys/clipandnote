import AppKit

/// A picker for "Export All ▸ Merge into PDF": lists every saved markup as a
/// thumbnail + checkbox. The list order is the PDF page order — set it with the
/// Sort popup or by dragging rows. An optional "Add page numbers" toggle stamps
/// each page.
final class MergeSelectionWindowController: NSWindowController,
        NSTableViewDataSource, NSTableViewDelegate {

    /// Sort presets. `.custom` = the user hand-reordered by dragging.
    private enum SortOrder: Int, CaseIterable {
        case custom, newest, oldest, nameAZ, nameZA
        var title: String {
            switch self {
            case .custom: return "Custom order"
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .nameAZ: return "Name (A–Z)"
            case .nameZA: return "Name (Z–A)"
            }
        }
    }

    private var ordered: [MarkupLibrary.Entry]      // current display/page order
    private var checkedIDs: Set<UUID>               // checked by id, survives re-sort
    private var sortOrder: SortOrder = .newest
    private var paginate = false

    private let tableView = NSTableView()
    private var sortPopup: NSPopUpButton!
    private var countLabel: NSTextField!
    private var mergeButton: NSButton!
    /// Selected entries (in current order) + whether to stamp page numbers.
    private let onMerge: ([MarkupLibrary.Entry], Bool) -> Void

    private static let rowType = NSPasteboard.PasteboardType("com.clipandnote.merge.row")

    init(entries: [MarkupLibrary.Entry], onMerge: @escaping ([MarkupLibrary.Entry], Bool) -> Void) {
        self.ordered = entries
        self.checkedIDs = Set(entries.map { $0.id })   // all ticked initially
        self.onMerge = onMerge
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Merge Markups into PDF"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        applySort()
        build()
        updateCount()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private func build() {
        let container = NSView()

        let title = NSTextField(labelWithString: "Tick the markups to combine — drag rows or Sort to set the page order:")
        title.font = .systemFont(ofSize: 12)
        title.translatesAutoresizingMaskIntoConstraints = false

        // Sort control.
        let sortLabel = NSTextField(labelWithString: "Sort:")
        sortLabel.font = .systemFont(ofSize: 12)
        sortLabel.textColor = .secondaryLabelColor
        sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sortPopup.controlSize = .small
        sortPopup.addItems(withTitles: SortOrder.allCases.map { $0.title })
        sortPopup.selectItem(at: sortOrder.rawValue)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))
        let sortRow = NSStackView(views: [sortLabel, sortPopup, NSView()])
        sortRow.orientation = .horizontal
        sortRow.spacing = 8
        sortRow.translatesAutoresizingMaskIntoConstraints = false

        // Reorderable table.
        let col = NSTableColumn(identifier: .init("markup"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.draggingDestinationFeedbackStyle = .gap

        let clip = NSScrollView()
        clip.hasVerticalScroller = true
        clip.drawsBackground = false
        clip.borderType = .bezelBorder
        clip.documentView = tableView
        clip.translatesAutoresizingMaskIntoConstraints = false

        // Page-numbers toggle.
        let pageNumbers = NSButton(checkboxWithTitle: "Add page numbers",
                                   target: self, action: #selector(togglePaginate(_:)))
        pageNumbers.state = paginate ? .on : .off
        pageNumbers.font = .systemFont(ofSize: 12)

        // Footer: select all/none + count + actions.
        let selectAll = NSButton(title: "All", target: self, action: #selector(checkAll(_:)))
        let selectNone = NSButton(title: "None", target: self, action: #selector(checkNone(_:)))
        [selectAll, selectNone].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // Esc
        mergeButton = NSButton(title: "Merge into PDF…", target: self, action: #selector(merge(_:)))
        mergeButton.bezelStyle = .rounded
        mergeButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [selectAll, selectNone, countLabel,
                                         NSView(), pageNumbers, cancel, mergeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(sortRow)
        container.addSubview(clip)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            sortRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            sortRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            sortRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            clip.topAnchor.constraint(equalTo: sortRow.bottomAnchor, constant: 10),
            clip.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            clip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            footer.topAnchor.constraint(equalTo: clip.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        window?.contentView = container
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { ordered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = ordered[row]
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowCheckToggled(_:)))
        check.state = checkedIDs.contains(entry.id) ? .on : .off
        check.translatesAutoresizingMaskIntoConstraints = false

        let thumb = NSImageView()
        thumb.image = MarkupLibrary.shared.thumbnail(entry.id)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 72).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let date = NSTextField(labelWithString: Self.dateFmt.string(from: entry.createdAt))
        date.font = .systemFont(ofSize: 11)
        date.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, date])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let rowView = NSStackView(views: [check, thumb, text])
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 10
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return rowView
    }

    // Drag-to-reorder.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation)
        -> NSDragOperation {
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }   // only between rows
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let s = item.string(forType: Self.rowType), let from = Int(s) else { return false }
        var to = row
        let moved = ordered.remove(at: from)
        if from < to { to -= 1 }
        ordered.insert(moved, at: max(0, min(to, ordered.count)))
        // A manual reorder means the preset no longer describes the order.
        sortOrder = .custom
        sortPopup.selectItem(at: SortOrder.custom.rawValue)
        tableView.reloadData()
        return true
    }

    // MARK: Sort / selection

    private func applySort() {
        switch sortOrder {
        case .custom: break   // leave the user's order untouched
        case .newest: ordered.sort { $0.createdAt > $1.createdAt }
        case .oldest: ordered.sort { $0.createdAt < $1.createdAt }
        case .nameAZ: ordered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA: ordered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    private func updateCount() {
        let n = checkedIDs.count
        countLabel.stringValue = "\(n) selected"
        mergeButton.isEnabled = n > 0
    }

    // MARK: Actions

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        guard let order = SortOrder(rawValue: sender.indexOfSelectedItem) else { return }
        sortOrder = order
        applySort()
        tableView.reloadData()
    }

    @objc private func togglePaginate(_ sender: NSButton) { paginate = (sender.state == .on) }

    @objc private func rowCheckToggled(_ sender: NSButton) {
        let r = tableView.row(for: sender)
        guard r >= 0, r < ordered.count else { return }
        let id = ordered[r].id
        if sender.state == .on { checkedIDs.insert(id) } else { checkedIDs.remove(id) }
        updateCount()
    }
    @objc private func checkAll(_ sender: Any?) { setAll(true) }
    @objc private func checkNone(_ sender: Any?) { setAll(false) }
    private func setAll(_ on: Bool) {
        checkedIDs = on ? Set(ordered.map { $0.id }) : []
        tableView.reloadData()
        updateCount()
    }

    @objc private func cancel(_ sender: Any?) { close() }
    @objc private func merge(_ sender: Any?) {
        let selected = ordered.filter { checkedIDs.contains($0.id) }   // keeps current order
        close()
        onMerge(selected, paginate)
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
