import AppKit

/// Owns the menu-bar status item and builds the snapshot menu. The exact command
/// list matches the spec: the six capture commands, then the last 10 recent
/// markups as clickable PNG thumbnails that paste into the active field.
final class StatusItemController {
    /// Fired when the user picks a capture command.
    var onCapture: ((CaptureKind) -> Void)?
    /// Fired when the user clicks a recent markup (index into the recents list).
    var onPickRecent: ((Int) -> Void)?
    var onOpenGallery: (() -> Void)?
    var onPreferences: (() -> Void)?

    private let statusItem: NSStatusItem
    /// Recent markups shown at the bottom of the menu (thumbnail + title).
    private var recents: [(title: String, thumbnail: NSImage?)] = []

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                   accessibilityDescription: "clipandnote")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    /// Replace the recent-markups list and rebuild the menu.
    func updateRecents(_ items: [(title: String, thumbnail: NSImage?)]) {
        recents = Array(items.prefix(10))
        rebuildMenu()
    }

    /// Rebuild the menu (e.g. after shortcuts change in Preferences).
    func rebuild() { rebuildMenu() }

    private func rebuildMenu() {
        let menu = NSMenu()

        for command in CaptureCommand.allCases {
            addCapture(menu, command)
        }

        menu.addItem(.separator())

        let header = NSMenuItem(title: "Recent Markups", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if recents.isEmpty {
            let empty = NSMenuItem(title: "  No markups yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (i, item) in recents.enumerated() {
                let mi = NSMenuItem(title: item.title,
                                    action: #selector(pickRecent(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.tag = i
                if let thumb = item.thumbnail {
                    let t = thumb.copy() as! NSImage
                    t.size = NSSize(width: 32, height: 20)
                    mi.image = t
                }
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())

        let gallery = NSMenuItem(title: "Markup Library…",
                                 action: #selector(openGallery), keyEquivalent: "0")
        gallery.target = self
        menu.addItem(gallery)

        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(openPreferences),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(NSMenuItem(title: "Quit clipandnote",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func addCapture(_ menu: NSMenu, _ command: CaptureCommand) {
        let sc = AppSettings.shared.shortcut(for: command)
        let item = NSMenuItem(title: command.title, action: #selector(capture(_:)),
                              keyEquivalent: sc.menuKeyEquivalent)
        // Status-item menu key equivalents are display-only (the menu isn't in
        // the main menu bar) — the global hotkey does the actual firing.
        if !sc.isNone { item.keyEquivalentModifierMask = sc.flags }
        item.target = self
        item.representedObject = command.kind
        menu.addItem(item)
    }

    @objc private func capture(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? CaptureKind else { return }
        onCapture?(kind)
    }

    @objc private func pickRecent(_ sender: NSMenuItem) {
        onPickRecent?(sender.tag)
    }

    @objc private func openGallery() {
        onOpenGallery?()
    }

    @objc private func openPreferences() {
        onPreferences?()
    }
}
