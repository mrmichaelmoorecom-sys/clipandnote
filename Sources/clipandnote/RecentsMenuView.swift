import AppKit

/// One recent-markup row's data shown in the menu-bar list.
struct RecentRowItem {
    let title: String
    let subtitle: String?      // "Markup · 1000 × 640", etc.
    let thumbnail: NSImage?
}

/// A scrollable list of recent markups, embedded as a custom NSMenuItem view in
/// the status-bar menu. Rich rows (numbered badge + thumbnail + two-line text)
/// to match clipandcue's clipboard list look. NSMenu can't show its own
/// scrollbar, so we host an NSScrollView inside.
final class RecentsMenuView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    /// Fired with the index of the clicked row. The owner closes the menu and
    /// opens the entry.
    var onPick: ((Int) -> Void)?

    private let listWidth: CGFloat = 320
    private let rowHeight: CGFloat = 52
    private let visibleRows: CGFloat = 7

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: listWidth,
                                 height: rowHeight * visibleRows))

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
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

    func setRecents(_ items: [RecentRowItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            let row = RecentRow(index: i, item: item)
            row.onClick = { [weak self] idx in
                self?.enclosingMenuItem?.menu?.cancelTracking()
                self?.onPick?(idx)
            }
            stack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let visible = min(CGFloat(items.count), visibleRows)
        frame.size = NSSize(width: listWidth, height: max(rowHeight, rowHeight * visible))
    }
}

/// One row in the recents list: numbered badge + thumbnail + two-line text.
private final class RecentRow: NSView {
    let index: Int
    var onClick: ((Int) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(index: Int, item: RecentRowItem) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true

        // Numbered badge on the left (1, 2, 3, …) — matches clipandcue's style.
        let badge = NSTextField(labelWithString: "\(index + 1)")
        badge.font = .systemFont(ofSize: 13, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        let badgeBg = NSView()
        badgeBg.wantsLayer = true
        badgeBg.layer?.cornerRadius = 6
        badgeBg.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.5).cgColor
        badgeBg.translatesAutoresizingMaskIntoConstraints = false
        badgeBg.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: badgeBg.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: badgeBg.centerYAnchor),
        ])

        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        thumb.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumb.image = item.thumbnail
        thumb.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.usesSingleLineMode = true
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let subtitle = NSTextField(labelWithString: item.subtitle ?? "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.cell?.usesSingleLineMode = true
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.spacing = 1
        text.alignment = .leading
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badgeBg)
        addSubview(thumb)
        addSubview(text)
        NSLayoutConstraint.activate([
            badgeBg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badgeBg.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeBg.widthAnchor.constraint(equalToConstant: 26),
            badgeBg.heightAnchor.constraint(equalToConstant: 26),

            thumb.leadingAnchor.constraint(equalTo: badgeBg.trailingAnchor, constant: 10),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 44),
            thumb.heightAnchor.constraint(equalToConstant: 30),

            text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
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
