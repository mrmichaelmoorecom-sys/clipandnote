import AppKit

/// One recent-markup row's data shown in the menu-bar list.
struct RecentRowItem {
    let title: String
    let subtitle: String?      // unused since the user removed the second line
    let thumbnail: NSImage?
}

/// A floating dropdown for the menu-bar status item — clipandnote's equivalent
/// of clipandcue's clipboard panel. Wraps an NSPopover so we get translucent
/// vibrancy, the little arrow tail pointing at the status icon, outside-click
/// dismissal, and Esc handling all for free.
final class StatusDropdownPanel: NSObject, NSPopoverDelegate {
    let content = StatusDropdownContent()
    private let popover = NSPopover()
    private let hostController = NSViewController()

    private static let dropdownSize = NSSize(width: 320, height: 500)

    override init() {
        super.init()
        // NSPopover defaults to the .popover NSVisualEffectMaterial — a
        // deliberately light, very-translucent vibrancy. Pinning the
        // appearance to .vibrantDark makes the chrome (including the arrow
        // tail) render in dark mode in either system theme, but the body
        // still uses .popover, which on a dark theme is only mildly dark.
        // To get a genuinely dark menu-style backdrop we also walk the
        // popover's window once it shows and force every NSVisualEffectView
        // inside to .menu material (see popoverDidShow). That's the only
        // entry point AppKit gives us into NSPopover's private chrome view.
        let host = NSView(frame: NSRect(origin: .zero, size: Self.dropdownSize))

        // NO custom backdrop view inside. NSPopover's arrow tail is drawn
        // OUTSIDE the content view's bounds, so any NSVisualEffectView or
        // coloured fill we add fills only the body — leaving a fully
        // transparent arrow tail (which is what the body's previous
        // .menu-material + black-tint backdrop produced visually). Letting
        // NSPopover render its native .popover material on both body and
        // tail is the only way to get a tail that matches the body. The
        // pinned .vibrantDark appearance (below) ensures both render in
        // dark mode regardless of system theme.
        host.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        hostController.view = host
        popover.contentViewController = hostController
        popover.contentSize = Self.dropdownSize
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// Show below the status item button — `.minY` makes the tail point up at
    /// the icon, matching clipandcue.
    func show(relativeTo button: NSView) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }

    // MARK: NSPopoverDelegate — darken the body to match the dark chrome

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else { return }
        // The popover's window's contentView has a private NSVisualEffectView
        // (the chrome) that AppKit doesn't otherwise let us touch. Walking
        // the hierarchy and forcing material = .menu gives us the saturated
        // dark menu look (clipandcue's screenshot vibe) instead of the
        // washed-out .popover default. Run it after the next runloop tick
        // too, because the visual-effect view's material can be re-applied
        // during the popover's own setup pass.
        applyDarkMaterial(to: window.contentView)
        DispatchQueue.main.async { [weak self] in
            self?.applyDarkMaterial(to: self?.popover.contentViewController?.view.window?.contentView)
        }
    }

    private func applyDarkMaterial(to view: NSView?) {
        guard let view else { return }
        if let vfx = view as? NSVisualEffectView {
            vfx.material = .menu
            vfx.state = .active
            vfx.blendingMode = .behindWindow
        }
        for sub in view.subviews { applyDarkMaterial(to: sub) }
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

        // -- App title header + capture commands --
        // Matches clipandcue's pattern of putting the app name at the very
        // top of the dropdown — coloured in clipandnote's brand purple
        // (#a29ab1, the lighter of the two mark_accent_v2.svg tones) so it
        // reads as branded chrome rather than a generic section label.
        let captureHeader = NSTextField(labelWithString: "clipandnote")
        captureHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        captureHeader.textColor = NSColor(srgbRed: 0xa2/255.0,
                                          green: 0x9a/255.0,
                                          blue: 0xb1/255.0,
                                          alpha: 1)
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
        // separator0 underlines the app-name title (clipandcue does the same).
        let separator0 = thinSeparator()
        let separator1 = thinSeparator()
        let separator2 = thinSeparator()

        let outer = NSStackView(views: [
            captureHeader, separator0, captureColumn,
            separator1,
            recentsHeader, recentsScroll,
            separator2,
            actionBar,
        ])
        outer.orientation = .vertical
        outer.spacing = 4
        outer.alignment = .leading
        outer.distribution = .fill
        // No horizontal edge inset on the stack — separators need to span
        // the popover edge-to-edge (like NSMenu separators), and content
        // rows get their own explicit 10pt leading/trailing constraints
        // below. Top / bottom stay padded.
        outer.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 6, right: 0)
        outer.setCustomSpacing(6, after: captureHeader)
        outer.setCustomSpacing(4, after: separator0)
        outer.setCustomSpacing(8, after: captureColumn)
        outer.setCustomSpacing(8, after: separator1)
        outer.setCustomSpacing(2, after: recentsHeader)
        outer.setCustomSpacing(4, after: recentsScroll)
        outer.setCustomSpacing(4, after: separator2)
        outer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(outer)
        let pad: CGFloat = 10
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Content rows — inset 10pt on each side.
            captureHeader.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: pad),
            captureColumn.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: pad),
            captureColumn.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -2 * pad),
            recentsHeader.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: pad),
            recentsScroll.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: pad),
            recentsScroll.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -2 * pad),
            recentsScroll.heightAnchor.constraint(equalToConstant: 260),
            actionBar.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: pad),
            actionBar.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -2 * pad),

            // Separators — full popover width, like NSMenu divider cells.
            separator0.widthAnchor.constraint(equalTo: outer.widthAnchor),
            separator1.widthAnchor.constraint(equalTo: outer.widthAnchor),
            separator2.widthAnchor.constraint(equalTo: outer.widthAnchor),
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
        heightAnchor.constraint(equalToConstant: 24).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false

        let kb = NSTextField(labelWithString: equiv)
        kb.font = .systemFont(ofSize: 11)
        kb.textColor = .secondaryLabelColor
        kb.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(kb)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            kb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
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
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.state = checked ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(checkboxToggled)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        // NSButton with .switch + empty title still reserves room for a title,
        // expanding to fill the row. Pin the width to just the visible
        // checkmark and stop it from stretching.
        checkbox.widthAnchor.constraint(equalToConstant: 18).isActive = true
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)

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
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 34),
            thumb.heightAnchor.constraint(equalToConstant: 24),
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
