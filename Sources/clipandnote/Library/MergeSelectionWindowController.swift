import AppKit

/// A picker for "Export All ▸ Merge into PDF": lists every saved markup as a
/// thumbnail + checkbox, newest first, so you tick exactly which ones (and in
/// what order, most-recent → oldest) get combined into a single PDF.
final class MergeSelectionWindowController: NSWindowController {
    private let entries: [MarkupLibrary.Entry]
    private var checked: [Bool]
    private var checkboxes: [NSButton] = []
    private var countLabel: NSTextField!
    private var mergeButton: NSButton!
    private let onMerge: ([MarkupLibrary.Entry]) -> Void

    init(entries: [MarkupLibrary.Entry], onMerge: @escaping ([MarkupLibrary.Entry]) -> Void) {
        self.entries = entries
        self.checked = Array(repeating: true, count: entries.count)
        self.onMerge = onMerge
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Merge Markups into PDF"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
        updateCount()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private func build() {
        let container = NSView()

        let title = NSTextField(labelWithString: "Tick the markups to combine, newest first:")
        title.font = .systemFont(ofSize: 12)
        title.translatesAutoresizingMaskIntoConstraints = false

        // Scrolling list of selectable rows.
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        for i in entries.indices { list.addArrangedSubview(makeRow(i)) }

        let clip = NSScrollView()
        clip.hasVerticalScroller = true
        clip.drawsBackground = false
        clip.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        clip.documentView = doc
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

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
                                         NSView(), cancel, mergeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(clip)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            clip.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            clip.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            clip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            footer.topAnchor.constraint(equalTo: clip.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        window?.contentView = container
    }

    private func makeRow(_ i: Int) -> NSView {
        let entry = entries[i]
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
        check.state = .on
        check.tag = i
        checkboxes.append(check)

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

        let row = NSStackView(views: [check, thumb, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return row
    }

    private func updateCount() {
        let n = checked.filter { $0 }.count
        countLabel.stringValue = "\(n) selected"
        mergeButton.isEnabled = n > 0
    }

    @objc private func toggle(_ sender: NSButton) {
        checked[sender.tag] = (sender.state == .on)
        updateCount()
    }
    @objc private func checkAll(_ sender: Any?) { setAll(true) }
    @objc private func checkNone(_ sender: Any?) { setAll(false) }
    private func setAll(_ on: Bool) {
        for i in checked.indices { checked[i] = on; checkboxes[i].state = on ? .on : .off }
        updateCount()
    }

    @objc private func cancel(_ sender: Any?) { close() }
    @objc private func merge(_ sender: Any?) {
        let selected = entries.enumerated().filter { checked[$0.offset] }.map { $0.element }
        close()
        onMerge(selected)
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
