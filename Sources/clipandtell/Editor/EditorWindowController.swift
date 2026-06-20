import AppKit

/// A markup editor window. v0.1 displays the captured image in a scrollable,
/// zoomable view; the selectable-object annotation canvas (arrows, text, shapes,
/// blur, pasted-image objects) is layered on in the next phase.
final class EditorWindowController: NSWindowController {
    private let imageView = NSImageView()

    convenience init(image: NSImage) {
        let size = image.size
        // Cap the initial window to something sane while fitting the capture.
        let maxW: CGFloat = 1400, maxH: CGFloat = 900
        let scale = min(1, min(maxW / max(size.width, 1), maxH / max(size.height, 1)))
        let contentRect = NSRect(x: 0, y: 0,
                                 width: max(size.width * scale, 320),
                                 height: max(size.height * scale, 240))

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Untitled Markup"
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)

        let scroll = NSScrollView(frame: contentRect)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: size)
        scroll.documentView = imageView

        window.contentView = scroll
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
