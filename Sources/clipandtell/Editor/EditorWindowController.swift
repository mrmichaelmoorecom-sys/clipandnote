import AppKit

/// A markup editor window: a tool palette across the top and the interactive
/// `CanvasView` (in a scroll view) below.
final class EditorWindowController: NSWindowController {

    private var canvas: CanvasView!

    /// Tools in palette order; index maps to the segmented control.
    private let tools: [(Tool, String, String)] = [
        (.select, "cursorarrow", "Select"),
        (.arrow, "arrow.up.left", "Arrow"),
        (.line, "line.diagonal", "Line"),
        (.rectangle, "rectangle", "Rectangle"),
        (.ellipse, "circle", "Ellipse"),
        (.freehand, "scribble", "Pen"),
        (.text, "textformat", "Text"),
        (.highlighter, "highlighter", "Highlighter"),
        (.pixelate, "mosaic", "Pixelate"),
    ]
    private var toolSeg: NSSegmentedControl!

    convenience init(image: NSImage) {
        self.init(document: MarkupDocument(baseImage: image, objects: [],
                                           canvasSize: image.size))
    }

    convenience init(document: MarkupDocument) {
        let canvasSize = document.canvasSize
        let maxW: CGFloat = 1400, maxH: CGFloat = 900
        let contentW = min(max(canvasSize.width, 480), maxW)
        let contentH = min(max(canvasSize.height + 48, 360), maxH)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Untitled Markup"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)

        buildUI(document: document)
    }

    private func buildUI(document: MarkupDocument) {
        guard let window = window else { return }
        let container = NSView()

        // --- Tool palette ---
        let seg = NSSegmentedControl(
            images: tools.map { NSImage(systemSymbolName: $0.1, accessibilityDescription: $0.2)
                ?? NSImage() },
            trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        seg.segmentStyle = .texturedRounded
        seg.selectedSegment = 0
        for (i, t) in tools.enumerated() { seg.setToolTip(t.2, forSegment: i) }
        toolSeg = seg

        let colorWell = NSColorWell()
        colorWell.color = RGBAColor.red.nsColor
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 30,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyFlattened))
        copyButton.bezelStyle = .rounded

        let palette = NSStackView(views: [seg, colorWell, widthSlider, NSView(), copyButton])
        palette.orientation = .horizontal
        palette.spacing = 10
        palette.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        palette.translatesAutoresizingMaskIntoConstraints = false

        // --- Canvas ---
        let canvas = CanvasView(document: document)
        self.canvas = canvas
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        scroll.backgroundColor = NSColor(white: 0.18, alpha: 1)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(palette)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            palette.topAnchor.constraint(equalTo: container.topAnchor),
            palette.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            palette.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            palette.heightAnchor.constraint(equalToConstant: 44),

            scroll.topAnchor.constraint(equalTo: palette.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container
        window.makeFirstResponder(canvas)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.tool = tools[sender.selectedSegment].0
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.strokeColor = sender.color
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.lineWidth = CGFloat(sender.doubleValue)
    }

    @objc private func copyFlattened() {
        canvas.copy(nil)
    }

    /// Flattened PNG of the current markup (used by the dev demo hook).
    func canvasFlattenedPNG() -> Data? {
        canvas.flatten()?.pngData()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
