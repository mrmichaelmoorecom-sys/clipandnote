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
    var onExportAll: (() -> Void)?
    var onPreferences: (() -> Void)?

    private let statusItem: NSStatusItem
    /// Recent markups shown at the bottom of the menu (thumbnail + title +
    /// subtitle, like clipandcue's clipboard list).
    private var recents: [RecentRowItem] = []

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = Self.crispMenuBarIcon() {
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                       accessibilityDescription: "clipandnote")
                button.image?.isTemplate = true
            }
        }
        rebuildMenu()
    }

    /// Load the @2x template PNG and re-render it ourselves into a fresh
    /// `NSBitmapImageRep` whose pixel dimensions exactly match the Retina menu-
    /// bar pixel grid, with interpolation turned off — so each source pixel
    /// snaps to a device pixel instead of getting smoothed by AppKit's default
    /// auto-scale at draw time. Template tinting then paints onto an already-
    /// crisp glyph instead of a blurred one.
    private static func crispMenuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubarTemplate", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }

        // Target: 12pt tall in the menu bar (matches clipandcue's visual size);
        // width preserves the source's aspect. @2x because every modern Mac is
        // Retina; the rep is built at the matching device-pixel size.
        let pointHeight: CGFloat = 16
        let aspect = src.size.width / max(src.size.height, 1)
        let pointWidth = (pointHeight * aspect).rounded()
        let scale: CGFloat = 2
        let pxW = Int(pointWidth * scale)
        let pxH = Int(pointHeight * scale)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: pxW, pixelsHigh: pxH, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: pxW * 4, bitsPerPixel: 32) else { return nil }
        rep.size = NSSize(width: pointWidth, height: pointHeight)   // @2x rep

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .none
        ctx.cgContext.interpolationQuality = .none
        src.draw(in: NSRect(x: 0, y: 0, width: pointWidth, height: pointHeight),
                 from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pointWidth, height: pointHeight))
        image.addRepresentation(rep)
        image.isTemplate = true   // monochrome; the OS tints after our crisp render
        return image
    }

    /// Replace the recent-markups list and rebuild the menu.
    func updateRecents(_ items: [RecentRowItem]) {
        recents = Array(items.prefix(60))
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
            // All recents in a single scrolling list (NSMenu has no scrollbar
            // of its own — we host an NSScrollView inside a custom item view).
            let listItem = NSMenuItem()
            let list = RecentsMenuView()
            list.setRecents(recents)
            list.onPick = { [weak self] i in self?.onPickRecent?(i) }
            listItem.view = list
            menu.addItem(listItem)
        }

        menu.addItem(.separator())

        let gallery = NSMenuItem(title: "Markup Library…",
                                 action: #selector(openGallery), keyEquivalent: "0")
        gallery.target = self
        menu.addItem(gallery)

        let exportAll = NSMenuItem(title: "Export All Markups…",
                                   action: #selector(exportAll), keyEquivalent: "")
        exportAll.target = self
        menu.addItem(exportAll)

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

    @objc private func openGallery() {
        onOpenGallery?()
    }

    @objc private func exportAll() {
        onExportAll?()
    }

    @objc private func openPreferences() {
        onPreferences?()
    }
}
