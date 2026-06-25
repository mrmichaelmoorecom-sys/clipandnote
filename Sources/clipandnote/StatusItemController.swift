import AppKit

/// Owns the menu-bar status item. Clicking the icon now opens a floating
/// dropdown panel (clipandcue-style) instead of a plain NSMenu so we can
/// host a checkbox-selectable recents list and a horizontal action bar.
final class StatusItemController: NSObject {
    var onCapture: ((CaptureKind) -> Void)?
    /// Fired when the user clicks a recent markup (index into the recents list).
    var onPickRecent: ((Int) -> Void)?
    /// Fired when the user drag-reorders a recent (from index, to index).
    var onReorderRecent: ((Int, Int) -> Void)?
    var onOpenGallery: (() -> Void)?
    /// Open an existing image / .can file via the system open panel.
    var onOpenFile: (() -> Void)?
    /// Fired with the indices of currently-checked recents. Empty array =
    /// "export everything" — the action bar's Export button title reflects that.
    var onExportSelected: (([Int]) -> Void)?
    /// Fired with the indices of checked recents to delete. Empty = "open the
    /// library to delete."
    var onDeleteSelected: (([Int]) -> Void)?
    var onPreferences: (() -> Void)?
    /// Open a fresh blank editor window ("New clipandnote").
    var onNewWindow: (() -> Void)?

    private let statusItem: NSStatusItem
    private let panel = StatusDropdownPanel()
    private var recents: [RecentRowItem] = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            if let img = Self.crispMenuBarIcon() {
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                       accessibilityDescription: "clipandnote")
                button.image?.isTemplate = true
            }
            button.target = self
            button.action = #selector(toggle)
        }

        panel.content.onCapture       = { [weak self] kind in self?.onCapture?(kind) }
        panel.content.onPickRecent    = { [weak self] idx  in self?.onPickRecent?(idx) }
        panel.content.onMoveRecent    = { [weak self] f, t in self?.onReorderRecent?(f, t) }
        panel.content.onOpenGallery   = { [weak self]      in self?.onOpenGallery?() }
        panel.content.onOpenFile      = { [weak self]      in self?.onOpenFile?() }
        panel.content.onDelete        = { [weak self] is_  in self?.onDeleteSelected?(is_) }
        panel.content.onNewWindow     = { [weak self]      in self?.onNewWindow?() }
        panel.content.onPreferences   = { [weak self]      in self?.onPreferences?() }
        panel.content.onExport        = { [weak self] is_  in self?.onExportSelected?(is_) }
        panel.content.onQuit          = {                     NSApp.terminate(nil) }
        panel.content.onClose         = { [weak self]      in self?.panel.close() }

        rebuildCaptureCommands()
        panel.content.setRecents(recents)
    }

    /// Re-emit the capture list (used when a shortcut changes in Preferences).
    func rebuild() {
        rebuildCaptureCommands()
        panel.content.setRecents(recents)
    }

    /// Replace the recent-markups list (called from AppDelegate.refreshRecents).
    func updateRecents(_ items: [RecentRowItem]) {
        recents = Array(items.prefix(60))
        panel.content.setRecents(recents)
    }

    private func rebuildCaptureCommands() {
        let commands = CaptureCommand.allCases.map { (command: CaptureCommand) in
            let sc = AppSettings.shared.shortcut(for: command)
            return (title: command.title, kind: command.kind, equiv: sc.display)
        }
        panel.content.setCaptureCommands(commands)
    }

    // MARK: Toggle the popover

    @objc private func toggle() {
        if panel.isShown {
            panel.close()
        } else if let button = statusItem.button {
            // NSPopover handles positioning, the arrow tail, outside-click
            // dismissal, and Esc for us — much simpler than the old NSPanel +
            // global-monitor dance.
            panel.show(relativeTo: button)
        }
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
        rep.size = NSSize(width: pointWidth, height: pointHeight)
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
        image.isTemplate = true
        return image
    }
}
