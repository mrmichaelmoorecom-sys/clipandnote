import AppKit

/// A scrollable list of recent markups, embedded as a custom NSMenuItem view in
/// the status-bar menu. Gives a real vertical scrollbar (NSMenu can't show one
/// natively) so every recent is reachable in one continuous list.
final class RecentsMenuView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    /// Fired with the index of the clicked row. The owner closes the menu and
    /// opens the entry.
    var onPick: ((Int) -> Void)?

    /// Width matches the rest of the status menu; height is capped so the
    /// scrollbar appears when there are more than ~8 entries.
    private let listWidth: CGFloat = 280
    private let rowHeight: CGFloat = 38
    private let visibleRows: CGFloat = 8

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: listWidth,
                                 height: rowHeight * visibleRows))

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy   // always-visible scrollbar, like the screenshot
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setRecents(_ items: [(title: String, thumbnail: NSImage?)]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            let row = RecentRow(index: i, title: item.title, thumbnail: item.thumbnail)
            row.onClick = { [weak self] idx in
                self?.enclosingMenuItem?.menu?.cancelTracking()
                self?.onPick?(idx)
            }
            stack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Resize the view's own frame to the cap (NSMenu uses the view's frame
        // for the row height — without this it can collapse to 0).
        let visible = min(CGFloat(items.count), visibleRows)
        frame.size = NSSize(width: listWidth, height: max(rowHeight, rowHeight * visible))
    }
}

/// One row in the recents list: thumbnail + title, with hover highlight.
private final class RecentRow: NSView {
    let index: Int
    var onClick: ((Int) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(index: Int, title: String, thumbnail: NSImage?) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true

        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 2
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        thumb.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumb.image = thumbnail
        thumb.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(thumb)
        addSubview(label)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 36),
            thumb.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?(index) }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
        }
    }
}
