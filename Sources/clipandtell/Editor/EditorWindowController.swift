import AppKit

/// A markup editor window: a tool palette across the top and the interactive
/// `CanvasView` (in a scroll view) below.
final class EditorWindowController: NSWindowController {

    private var canvas: CanvasView!

    /// Tools in palette order: (tool, SF Symbol, label, shortcut key).
    private let tools: [(tool: Tool, symbol: String, label: String, key: String)] = [
        (.select, "cursorarrow", "Select", "V"),
        (.arrow, "arrow.up.left", "Arrow", "A"),
        (.line, "line.diagonal", "Line", "L"),
        (.rectangle, "rectangle", "Rectangle", "R"),
        (.ellipse, "circle", "Ellipse", "O"),
        (.freehand, "scribble", "Pen", "P"),
        (.text, "textformat", "Text", "T"),
        (.highlighter, "highlighter", "Highlighter", "H"),
        (.pixelate, "mosaic", "Pixelate", "X"),
    ]
    private var toolButtons: [ToolButton] = []
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
        let toolStack = NSStackView()
        toolStack.orientation = .horizontal
        toolStack.spacing = 2
        for t in tools {
            let b = ToolButton(tool: t.tool, symbolName: t.symbol, tooltip: "\(t.label)  (\(t.key))")
            b.isSelected = (t.tool == .select)
            b.onClick = { [weak self] in self?.pickTool(t.tool) }
            if t.tool == .text {
                b.onLongPress = { [weak self, weak b] in if let b { self?.showFontMenu(from: b) } }
            }
            toolButtons.append(b)
            toolStack.addArrangedSubview(b)
        }

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

        let palette = NSStackView(views: [toolStack, colors, slider, NSView(), copyButton])
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
        canvas.onToolChanged = { [weak self] t in self?.setActiveTool(t) }
        canvas.onCanvasResized = { [weak canvas] in
            guard let canvas, let clip = canvas.enclosingScrollView?.contentView else { return }
            let doc = canvas.frame.size, vis = clip.bounds.size
            let x = max(0, (doc.width - vis.width) / 2)
            let y = max(0, (doc.height - vis.height) / 2)
            canvas.scroll(NSPoint(x: x, y: y))
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        scroll.backgroundColor = NSColor(white: 0.16, alpha: 1)
        // Padding around the canvas so it reads as a distinct surface even amid a
        // cluttered desktop.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
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

    /// User picked a tool in the palette.
    private func pickTool(_ tool: Tool) {
        canvas.tool = tool
        setActiveTool(tool)
        window?.makeFirstResponder(canvas)
    }

    /// Reflect the active tool in the palette (also called when a keyboard
    /// shortcut changes the tool inside the canvas).
    private func setActiveTool(_ tool: Tool) {
        for b in toolButtons { b.isSelected = (b.tool == tool) }
    }

    /// Press-and-hold the text tool: choose from every installed font family.
    private func showFontMenu(from button: ToolButton) {
        let menu = NSMenu()
        let def = NSMenuItem(title: "System Font (default)",
                             action: #selector(pickFont(_:)), keyEquivalent: "")
        def.target = self
        def.representedObject = ""
        menu.addItem(def)
        menu.addItem(.separator())
        for family in NSFontManager.shared.availableFontFamilies {
            let item = NSMenuItem(title: family, action: #selector(pickFont(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 14) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: f])
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func pickFont(_ sender: NSMenuItem) {
        let family = sender.representedObject as? String ?? ""
        canvas.setActiveFont(family.isEmpty ? nil : family)
        pickTool(.text)
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
