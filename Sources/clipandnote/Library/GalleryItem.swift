import AppKit

/// One thumbnail in the gallery grid: preview image, name, and a pin badge.
final class GalleryItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("GalleryItem")

    private let thumb = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pinBadge = NSTextField(labelWithString: "📌")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.layer?.backgroundColor = NSColor.white.cgColor
        thumb.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        pinBadge.font = .systemFont(ofSize: 11)
        pinBadge.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(thumb)
        root.addSubview(nameLabel)
        root.addSubview(pinBadge)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            thumb.heightAnchor.constraint(equalToConstant: 124),
            nameLabel.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            pinBadge.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            pinBadge.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
        ])
        view = root
    }

    func configure(name: String, pinned: Bool, thumbnail: NSImage?) {
        thumb.image = thumbnail
        nameLabel.stringValue = name
        pinBadge.isHidden = !pinned
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
        }
    }
}
