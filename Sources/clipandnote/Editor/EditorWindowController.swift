import AppKit
import UniformTypeIdentifiers

/// A markup editor window: a tool palette across the top and the interactive
/// `CanvasView` (in a scroll view) below.
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    /// Even breathing room around the canvas, in points (window sizing + scroll insets).
    static let canvasMargin: CGFloat = 36

    private var canvas: CanvasView!
    /// The `.can` file backing this window, once saved/opened.
    private(set) var fileURL: URL?
    /// The library entry this window autosaves to (every capture has one).
    private(set) var libraryID: UUID?
    private var autosaveWork: DispatchWorkItem?

    /// Empty-state actions (the blank "home" window).
    var onRequestOpen: (() -> Void)?
    var onRequestCapture: (() -> Void)?
    var onCaptureImage: ((NSImage) -> Void)?
    var onOpenCanURL: ((URL) -> Void)?
    private var emptyState: NSView?

    /// Tools in palette order: (tool, SF Symbol, label, shortcut key).
    private let tools: [(tool: Tool, symbol: String, label: String, key: String)] = [
        (.select, "cursorarrow", "Select", "V"),
        (.crop, "crop", "Crop", "C"),
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
    private var sizeLabel: NSTextField!
    private var scrollView: NSScrollView!

    convenience init(image: NSImage) {
        self.init(document: MarkupDocument(baseImage: image, objects: [],
                                           canvasSize: image.size))
    }

    /// A blank "home" window — toolbar + an empty drop/open/capture area.
    convenience init() {
        self.init(document: MarkupDocument(baseImage: nil, objects: [],
                                           canvasSize: CGSize(width: 900, height: 560)))
    }

    private var isBlank: Bool { canvas.document.baseImage == nil && canvas.document.objects.isEmpty }

    convenience init(document: MarkupDocument) {
        let canvasSize = document.canvasSize
        let minW: CGFloat = 760           // enough for the full toolbar
        let margin = Self.canvasMargin    // even breathing room around the canvas
        let maxW: CGFloat = 1500, maxH: CGFloat = 950
        let contentW = min(max(canvasSize.width + margin * 2, minW), maxW)
        let contentH = min(max(canvasSize.height + 48 + margin * 2, 360), maxH)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Untitled Markup"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: minW, height: 320)
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

        // Layer up/down controls.
        let forward = IconButton(symbolName: "square.3.layers.3d.top.filled",
                                 tooltip: "Bring Forward  (⌘])")
        forward.onClick = { [weak self] in self?.canvas.bringForward(nil) }
        let backward = IconButton(symbolName: "square.3.layers.3d.bottom.filled",
                                  tooltip: "Send Backward  (⌘[)")
        backward.onClick = { [weak self] in self?.canvas.sendBackward(nil) }
        let layerStack = NSStackView(views: [forward, backward])
        layerStack.orientation = .horizontal
        layerStack.spacing = 2

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

        let sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        self.sizeLabel = sizeLabel

        let palette = NSStackView(views: [toolStack, layerStack, colors, slider, NSView(), sizeLabel, copyButton])
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
        canvas.onMutated = { [weak self] in
            self?.window?.isDocumentEdited = true
            self?.scheduleAutosave()
        }
        canvas.onCanvasResized = { [weak self] in self?.updateSizeLabel() }
        canvas.onCropped = { [weak self] in self?.resizeWindowToCanvas(); self?.updateSizeLabel() }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        scroll.backgroundColor = NSColor(white: 0.17, alpha: 1)
        // Even margin on every side via content insets. Unlike a centering clip
        // view, insets don't shift the clip's bounds origin, so mouse events keep
        // mapping correctly to canvas coordinates (hit-testing stays intact).
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.canvasMargin, left: Self.canvasMargin,
                                            bottom: Self.canvasMargin, right: Self.canvasMargin)
        scroll.scrollerInsets = NSEdgeInsets(top: -Self.canvasMargin, left: -Self.canvasMargin,
                                             bottom: -Self.canvasMargin, right: -Self.canvasMargin)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scroll

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
        window.delegate = self

        if document.baseImage == nil && document.objects.isEmpty {
            installEmptyState(in: container, below: bar)
            window.title = "clipandnote"
        }
    }

    func windowWillClose(_ notification: Notification) { autosaveNow() }

    // MARK: - Empty state (blank home window)

    private func installEmptyState(in container: NSView, below bar: NSView) {
        let zone = DropZoneView()
        zone.translatesAutoresizingMaskIntoConstraints = false
        zone.onImage = { [weak self] image in self?.onCaptureImage?(image) }
        zone.onCanURL = { [weak self] url in self?.onOpenCanURL?(url) }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Open a markup or capture a screenshot")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "or drag an image or .can file here")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let openBtn = NSButton(title: "Open…", target: self, action: #selector(emptyOpen))
        openBtn.bezelStyle = .rounded; openBtn.keyEquivalent = "\r"
        let captureBtn = NSButton(title: "Capture", target: self, action: #selector(emptyCapture))
        captureBtn.bezelStyle = .rounded
        let buttons = NSStackView(views: [openBtn, captureBtn]); buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, subtitle, buttons])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        zone.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: zone.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: zone.centerYAnchor),
        ])

        container.addSubview(zone)   // over the canvas, below the toolbar band
        NSLayoutConstraint.activate([
            zone.topAnchor.constraint(equalTo: bar.bottomAnchor),
            zone.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            zone.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            zone.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        emptyState = zone
    }

    @objc private func emptyOpen() { onRequestOpen?() }
    @objc private func emptyCapture() { onRequestCapture?() }

    private func dismissEmptyState() {
        emptyState?.removeFromSuperview()
        emptyState = nil
        window?.makeFirstResponder(canvas)
    }

    /// Replace the blank canvas with a captured/dropped image.
    func setBaseImage(_ image: NSImage) {
        canvas.document = MarkupDocument(baseImage: image, objects: [], canvasSize: image.size)
        canvas.setFrameSize(image.size)
        dismissEmptyState()
        DispatchQueue.main.async { [weak self] in self?.resizeWindowToCanvas(); self?.updateSizeLabel() }
    }

    /// Load a `.can` document into this window (from Open or a drop).
    func loadCan(_ doc: MarkupDocument, url: URL?) {
        canvas.document = doc
        canvas.setFrameSize(doc.canvasSize)
        if let url { setFileURL(url) }
        dismissEmptyState()
        DispatchQueue.main.async { [weak self] in self?.resizeWindowToCanvas(); self?.updateSizeLabel() }
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

    /// The live document (for creating/refreshing its library entry).
    var currentDocument: MarkupDocument { canvas.document }

    /// Flattened PNG of the current markup (used by the dev demo hook).
    func canvasFlattenedPNG() -> Data? {
        canvas.flatten()?.pngData()
    }

    // MARK: - Saving / opening .can files

    /// Adopt a file (after opening, or after the first save).
    func setFileURL(_ url: URL) {
        fileURL = url
        window?.representedURL = url
        window?.title = url.deletingPathExtension().lastPathComponent
        window?.isDocumentEdited = false
    }

    @objc func save(_ sender: Any?) {
        if let url = fileURL { write(to: url) } else { saveAs(sender) }
    }

    @objc func saveAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.canDocument]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent
            ?? snapshotTitle) + ".\(CanFile.ext)"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.write(to: url)
        }
    }

    private func write(to url: URL) {
        do {
            try CanFile.write(canvas.document, to: url)
            setFileURL(url)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    // MARK: Export

    @objc func exportPNG(_ sender: Any?) {
        exportData(ext: "png", type: .png) { MarkupExporter.png(self.canvas.document) }
    }
    @objc func exportPDF(_ sender: Any?) {
        exportData(ext: "pdf", type: .pdf) { MarkupExporter.pdf(self.canvas.document) }
    }
    @objc func exportSVG(_ sender: Any?) {
        exportData(ext: "svg", type: .svg) { SVGExporter.svg(self.canvas.document).data(using: .utf8) }
    }

    private func exportData(ext: String, type: UTType, make: @escaping () -> Data?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue =
            (fileURL?.deletingPathExtension().lastPathComponent ?? snapshotTitle) + ".\(ext)"
        panel.beginSheetModal(for: window!) { resp in
            guard resp == .OK, let url = panel.url, let data = make() else { return }
            try? data.write(to: url)
        }
    }

    /// The snapshot's name (timestamp + AI label), shown as the window title and
    /// used as the default filename when saving.
    private(set) var snapshotTitle: String = "Untitled Markup"
    func setSnapshotTitle(_ title: String) {
        snapshotTitle = title
        window?.title = title
        if let id = libraryID { MarkupLibrary.shared.update(canvas.document, id: id, name: title) }
    }

    // MARK: - Library autosave

    /// Bind this window to a library entry; from now on edits autosave to it.
    func bindToLibrary(_ id: UUID) { libraryID = id }

    private func scheduleAutosave() {
        guard libraryID != nil else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosaveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Flush any pending autosave immediately (e.g. on close).
    func autosaveNow() {
        autosaveWork?.cancel(); autosaveWork = nil
        guard let id = libraryID else { return }
        MarkupLibrary.shared.update(canvas.document, id: id, name: snapshotTitle)
        window?.isDocumentEdited = false
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.resizeWindowToCanvas(); self?.updateSizeLabel() }
    }

    /// Resize the window so the canvas sits inside it with an even margin on
    /// every side (clamped to sane min/max; large captures keep margins and
    /// scroll within the inset band rather than filling edge-to-edge).
    private func resizeWindowToCanvas() {
        guard let window = window, let screen = window.screen ?? NSScreen.main else { return }
        let canvasSize = canvas.document.canvasSize
        let margin = Self.canvasMargin
        let minW: CGFloat = 760
        let vis = screen.visibleFrame
        let maxW = min(1500, vis.width - 40)
        let maxH = min(1100, vis.height - 40)
        let contentW = min(max(canvasSize.width + margin * 2, minW), maxW)
        let contentH = min(max(canvasSize.height + 44 + margin * 2, 360), maxH)
        let newFrame = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: contentW, height: contentH))
        var frame = window.frame
        // Keep the top-left corner anchored as the window grows/shrinks.
        let top = frame.maxY
        frame.size = newFrame.size
        frame.origin.y = top - newFrame.size.height
        window.setFrame(frame, display: true, animate: false)
        window.center()
    }

    private func updateSizeLabel() {
        let s = canvas.document.canvasSize
        sizeLabel?.stringValue = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
    }
}
