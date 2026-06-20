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
    private var colors: ColorPaletteView!
    private var widthSlider: NSSlider!

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

        let colors = ColorPaletteView()
        colors.translatesAutoresizingMaskIntoConstraints = false
        colors.setContentHuggingPriority(.required, for: .horizontal)
        self.colors = colors

        let slider = NSSlider(value: 4, minValue: 1, maxValue: 30,
                              target: self, action: #selector(widthChanged(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        self.widthSlider = slider

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyFlattened))
        copyButton.bezelStyle = .rounded

        let palette = NSStackView(views: [seg, colors, slider, NSView(), copyButton])
        palette.orientation = .horizontal
        palette.spacing = 10
        palette.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        palette.translatesAutoresizingMaskIntoConstraints = false

        // --- Canvas ---
        let canvas = CanvasView(document: document)
        self.canvas = canvas
        colors.onPick = { [weak canvas] c in canvas?.setActiveColor(c) }
        canvas.onSelectionChanged = { [weak self] obj in
            guard let self, let obj else { return }
            let c = obj.kind == .highlighter
                ? (obj.fill ?? .highlighter).nsColor.withAlphaComponent(1)
                : obj.stroke.nsColor
            self.colors.reflect(c)
            self.widthSlider.doubleValue = Double(obj.kind == .text ? obj.fontSize / 5 : obj.lineWidth)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        scroll.backgroundColor = NSColor(white: 0.18, alpha: 1)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // An opaque toolbar bar that fully owns the top band and catches every
        // click there — otherwise clicks fall through to the canvas behind it.
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(palette)

        // Scroll first (behind), bar second (in front) so the bar wins hit-testing.
        container.addSubview(scroll)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            palette.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            palette.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            palette.topAnchor.constraint(equalTo: bar.topAnchor),
            palette.bottomAnchor.constraint(equalTo: bar.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
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

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.setActiveWidth(CGFloat(sender.doubleValue))
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
