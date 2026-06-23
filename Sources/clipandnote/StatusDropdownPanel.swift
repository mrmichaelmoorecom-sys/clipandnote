import AppKit

/// One recent-markup row's data shown in the menu-bar list.
struct RecentRowItem {
    let title: String
    let subtitle: String?      // unused since the user removed the second line
    let thumbnail: NSImage?
}

/// A floating dropdown for the menu-bar status item — clipandnote's equivalent
/// of clipandcue's clipboard panel. Replaces the previous NSMenu so we can
/// host real checkboxes (so the user can multi-select recents and export them
/// in one go), a horizontal action bar at the bottom, and a scrolling list.
final class StatusDropdownPanel: NSPanel {
    let content = StatusDropdownContent()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let bg = RoundedPanelBackground()
        bg.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            content.topAnchor.constraint(equalTo: bg.topAnchor),
            content.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        contentView = bg
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {            // Esc
            content.onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class RoundedPanelBackground: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Content

/// The panel's contents: capture commands + scrolling recents list with
/// checkboxes + bottom action bar. Owns no app state — all decisions ride
/// callbacks back to `StatusItemController`.
final class StatusDropdownContent: NSView {
    var onCapture: ((CaptureKind) -> Void)?
    var onPickRecent: ((Int) -> Void)?
    var onOpenGallery: (() -> Void)?
    var onPreferences: (() -> Void)?
    /// Export Selected (indices into the current recents list). Empty array =
    /// "export all" (the button title flips when nothing's checked).
    var onExport: (([Int]) -> Void)?
    /// Quit the app.
    var onQuit: (() -> Void)?
    /// Close the panel (Esc, outside-click, after a row pick).
    var onClose: (() -> Void)?

    private let captureColumn = NSStackView()
    private let recentsScroll = NSScrollView()
    private let recentsColumn = NSStackView()
    private let exportButton = NSButton()
    private var recents: [RecentRowItem] = []
    private var checked: Set<Int> = []

    init() {
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setCaptureCommands(_ commands: [(title: String, kind: CaptureKind, equiv: String)]) {
        captureColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, cmd) in commands.enumerated() {
            let row = CaptureCommandRow(title: cmd.title, equiv: cmd.equiv)
            row.onClick = { [weak self] in
                self?.onCapture?(cmd.kind)
                self?.onClose?()
            }
            _ = i
            captureColumn.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: captureColumn.widthAnchor).isActive = true
        }
    }

    func setRecents(_ items: [RecentRowItem]) {
        recents = items
        checked = []
        rebuildRecentsRows()
        updateExportTitle()
    }

    private func rebuildRecentsRows() {
        recentsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in recents.enumerated() {
            let row = RecentRow(index: i, item: item, checked: checked.contains(i))
            row.onClick = { [weak self] idx in
                self?.onPickRecent?(idx)
                self?.onClose?()
            }
            row.onToggleCheck = { [weak self] idx, on in
                guard let self else { return }
                if on { self.checked.insert(idx) } else { self.checked.remove(idx) }
                self.updateExportTitle()
            }
            recentsColumn.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentsColumn.widthAnchor).isActive = true
        }
        if recents.isEmpty {
            let empty = NSTextField(labelWithString: "No markups yet")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            recentsColumn.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: recentsColumn.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 60).isActive = true
        }
    }

    private func updateExportTitle() {
        // Empty selection → "Export" (opens the thumbnail picker, like
        // 'Export All' used to). Non-empty selection → "Export N" (direct
        // export of the checked recents).
        exportButton.title = checked.isEmpty ? "Export" : "Export \(checked.count)"
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        // -- Capture column header + commands --
        let captureHeader = NSTextField(labelWithString: "Capture")
        captureHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        captureHeader.textColor = .secondaryLabelColor
        captureColumn.orientation = .vertical
        captureColumn.spacing = 0
        captureColumn.alignment = .leading
        captureColumn.distribution = .fill
        captureColumn.translatesAutoresizingMaskIntoConstraints = false

        // -- Recents header + scrolling list --
        let recentsHeader = NSTextField(labelWithString: "Recent Markups")
        recentsHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        recentsHeader.textColor = .secondaryLabelColor

        recentsColumn.orientation = .vertical
        recentsColumn.spacing = 0
        recentsColumn.alignment = .leading
        recentsColumn.distribution = .fill
        recentsColumn.translatesAutoresizingMaskIntoConstraints = false

        recentsScroll.hasVerticalScroller = true
        recentsScroll.scrollerStyle = .overlay
        recentsScroll.autohidesScrollers = true
        recentsScroll.drawsBackground = false
        recentsScroll.borderType = .noBorder
        recentsScroll.documentView = recentsColumn
        recentsScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recentsColumn.leadingAnchor.constraint(equalTo: recentsScroll.contentView.leadingAnchor),
            recentsColumn.trailingAnchor.constraint(equalTo: recentsScroll.contentView.trailingAnchor),
            recentsColumn.topAnchor.constraint(equalTo: recentsScroll.contentView.topAnchor),
            recentsColumn.widthAnchor.constraint(equalTo: recentsScroll.contentView.widthAnchor),
        ])

        // -- Bottom action bar --
        let libraryButton = makeFlatButton(title: "Library", symbol: "books.vertical") { [weak self] in
            self?.onOpenGallery?(); self?.onClose?()
        }
        exportButton.title = "Export All"
        exportButton.bezelStyle = .texturedRounded
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        let prefsButton = makeIconButton(symbol: "gear",
                                         tooltip: "Preferences") { [weak self] in
            self?.onPreferences?(); self?.onClose?()
        }
        let quitButton = makeIconButton(symbol: "power",
                                        tooltip: "Quit clipandnote") { [weak self] in
            self?.onQuit?()
        }

        let actionBar = NSStackView(views: [libraryButton, NSView(),
                                            exportButton, prefsButton, quitButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 8
        actionBar.alignment = .centerY
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        // -- Layout the column --
        let separator1 = thinSeparator()
        let separator2 = thinSeparator()

        let outer = NSStackView(views: [
            captureHeader, captureColumn,
            separator1,
            recentsHeader, recentsScroll,
            separator2,
            actionBar,
        ])
        outer.orientation = .vertical
        outer.spacing = 6
        outer.alignment = .leading
        outer.distribution = .fill
        outer.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        outer.setCustomSpacing(2, after: captureHeader)
        outer.setCustomSpacing(10, after: captureColumn)
        outer.setCustomSpacing(10, after: separator1)
        outer.setCustomSpacing(2, after: recentsHeader)
        outer.setCustomSpacing(10, after: recentsScroll)
        outer.setCustomSpacing(10, after: separator2)
        outer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(outer)
        // outer's 12pt horizontal edgeInsets — pin every child width to the
        // available content area so rows actually fill the panel (otherwise
        // .leading alignment leaves them hugging their intrinsic width).
        let contentInset: CGFloat = -24       // 12 left + 12 right
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            captureColumn.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: contentInset),
            recentsScroll.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: contentInset),
            recentsScroll.heightAnchor.constraint(equalToConstant: 320),
            actionBar.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: contentInset),
            separator1.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: contentInset),
            separator2.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: contentInset),
        ])
    }

    @objc private func exportTapped() {
        let indices = Array(checked).sorted()
        onExport?(indices)
        onClose?()
    }

    private func thinSeparator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func makeFlatButton(title: String, symbol: String, action: @escaping () -> Void) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }
        btn.bezelStyle = .texturedRounded
        ButtonActionHolder.attach(btn, action: action)
        return btn
    }

    private func makeIconButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let btn = NSButton(title: "", target: nil, action: nil)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            btn.image = img
        }
        btn.bezelStyle = .texturedRounded
        btn.imagePosition = .imageOnly
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        ButtonActionHolder.attach(btn, action: action)
        return btn
    }
}

/// Holder so we can pass a closure to NSButton's target/action machinery.
private final class ButtonActionHolder: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func trigger() { action() }

    static func attach(_ button: NSButton, action: @escaping () -> Void) {
        let holder = ButtonActionHolder(action)
        button.target = holder
        button.action = #selector(ButtonActionHolder.trigger)
        objc_setAssociatedObject(button, &Self.key, holder,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    private static var key: UInt8 = 0
}

// MARK: - Rows

/// A single capture command (Crosshair, Fullscreen, etc.) drawn as a row with
/// hover highlight and an optional keyboard-equivalent on the right.
private final class CaptureCommandRow: NSView {
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(title: String, equiv: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false

        let kb = NSTextField(labelWithString: equiv)
        kb.font = .systemFont(ofSize: 11)
        kb.textColor = .secondaryLabelColor
        kb.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(kb)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            kb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            kb.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta); trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }
    override func mouseDown(with event: NSEvent)    { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.selectedMenuItemColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1),
                         xRadius: 5, yRadius: 5).fill()
        }
    }
}

/// One recents row with a checkbox for multi-select export, a small thumbnail,
/// and a single-line name. No subtitle (per user request) — the row reads as
/// "is this one in the export batch? click to open."
private final class RecentRow: NSView {
    let index: Int
    var onClick: ((Int) -> Void)?
    var onToggleCheck: ((Int, Bool) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?
    private let checkbox = NSButton()

    init(index: Int, item: RecentRowItem, checked: Bool) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.state = checked ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(checkboxToggled)
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        thumb.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumb.image = item.thumbnail
        thumb.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.usesSingleLineMode = true
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(checkbox)
        addSubview(thumb)
        addSubview(title)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 38),
            thumb.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta); trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }
    override func mouseDown(with event: NSEvent) {
        // Only the body counts as a "row pick" — the checkbox itself uses its
        // own target/action and is invoked by NSButton's normal hit-testing.
        let local = convert(event.locationInWindow, from: nil)
        guard !checkbox.frame.insetBy(dx: -4, dy: -4).contains(local) else {
            super.mouseDown(with: event); return
        }
        onClick?(index)
    }

    @objc private func checkboxToggled() {
        onToggleCheck?(index, checkbox.state == .on)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.selectedMenuItemColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1),
                         xRadius: 5, yRadius: 5).fill()
        }
    }
}
