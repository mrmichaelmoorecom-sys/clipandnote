import AppKit
import UniformTypeIdentifiers

/// A markup editor window: a tool palette across the top and the interactive
/// `CanvasView` (in a scroll view) below.
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    /// Even breathing room around the canvas, in points (window sizing + scroll insets).
    static let canvasMargin: CGFloat = 36

    private var canvas: CanvasView!
    /// NSEvent monitor that catches mouseDown in the grey backdrop around the
    /// canvas and drops the current selection (the scroll view's clip view
    /// otherwise swallows those clicks). The active tool stays put.
    private var outsideClickMonitor: Any?
    /// Shared popover used by every tool button's ▼ to surface a tiny
    /// horizontal slider for that tool's primary scalar (width / opacity /
    /// font size). Reused so successive openings don't stack windows.
    private let toolValuePopover = ToolValuePopover()
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
        (.ocr, "text.viewfinder", "Grab Text  (OCR)", "I"),
        (.crop, "crop", "Crop", "C"),
        (.pixelate, "mosaic", "Pixelate", "X"),
        (.arrow, "arrow.up.left", "Arrow", "A"),
        (.doubleArrow, "arrow.left.and.right", "Curved Double Arrow", "D"),
        (.line, "line.diagonal", "Line", "L"),
        (.freehand, "scribble", "Pen", "P"),
        (.highlighter, "highlighter", "Highlighter", "H"),
        (.rectangle, "rectangle", "Rectangle", "R"),
        (.ellipse, "circle", "Ellipse", "O"),
        (.text, "textformat", "Text", "T"),
    ]
    private var toolButtons: [ToolButton] = []
    private var colors: ColorPaletteView!
    private var widthSlider: NSSlider!
    private var sizeLabel: NSTextField!
    private var bgWell: NSColorWell!
    private var scrollView: NSScrollView!
    private var fileNameLabel: NSTextField!
    private var footerView: NSView!

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
        let contentH = min(max(canvasSize.height + 56 + margin * 2, 360), maxH)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Untitled Markup"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: minW, height: 320)
        // Unified toolbar look: the toolbar fills the top band and the window
        // buttons float in it, vertically centered with room to breathe (like
        // Preview) instead of crammed into a short standard title bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        self.init(window: window)

        buildUI(document: document)
    }

    /// Tools whose icon previews the colored mark they'll draw on the canvas.
    private static let coloredTools: Set<Tool> = [
        .arrow, .doubleArrow, .line, .rectangle, .ellipse, .freehand, .text, .highlighter,
    ]

    /// Bundle resource name for the tool's vector icon (under `toolicons/`).
    private static func svgIconName(for tool: Tool) -> String? {
        switch tool {
        case .line: return "line"
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .freehand: return "freehand"
        case .text: return "text"
        case .highlighter: return "highlighter"
        case .pixelate: return "pixelate"
        case .doubleArrow: return "doublearrow"
        case .select, .crop, .arrow, .ocr: return nil   // keep their built-in glyphs
        }
    }

    /// Re-draw every colored tool icon — call after the active color changes.
    private func refreshColoredToolIcons() {
        for b in toolButtons where Self.coloredTools.contains(b.tool) { b.refreshIcon() }
    }

    /// A hairline vertical divider between toolbar groups.
    private func toolbarDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return line
    }

    private func buildUI(document: MarkupDocument) {
        guard let window = window else { return }
        let container = NSView()

        // --- Tool palette ---
        let toolStack = NSStackView()
        toolStack.orientation = .horizontal
        toolStack.spacing = 4
        for t in tools {
            let b = ToolButton(tool: t.tool, symbolName: t.symbol, tooltip: "\(t.label)  (\(t.key))")
            b.isSelected = (t.tool == .select)
            b.onClick = { [weak self] in self?.pickTool(t.tool) }
            // Every "tunable" tool gets the same ▼ → opacity-slider popover.
            // Width / size stay on the global toolbar slider; the per-tool
            // triangle is unified as "how translucent is this tool's output".
            // Rect / ellipse / text also get their non-scalar option
            // (outline-vs-filled, font family) riding above the slider so
            // those choices don't disappear.
            switch t.tool {
            case .highlighter, .text,
                 .arrow, .doubleArrow, .line, .freehand,
                 .rectangle, .ellipse:
                b.onShowMenu = { [weak self, weak b] in
                    if let b { self?.showOpacitySlider(from: b) }
                }
            default:
                break
            }
            // The arrow tool previews the actual rendered shape (handled in
            // ToolButton.draw) — give it the active color through a closure.
            if t.tool == .arrow {
                b.fillProvider = { [weak self] in self?.canvas?.strokeColor ?? .labelColor }
            }
            // For the SVG-driven tools whose output is a colored mark, the tool
            // icon previews that mark in the active color (with a thin contrast
            // outline that stays visible whether selected or not).
            if let svgName = Self.svgIconName(for: t.tool) {
                let colored = Self.coloredTools.contains(t.tool)
                b.customRender = { [weak self] _ in
                    guard let self else { return nil }
                    let fill: NSColor = colored
                        ? (t.tool == .highlighter
                           ? self.canvas.highlighterFill(self.canvas.strokeColor).nsColor
                           : self.canvas.strokeColor)
                        : .labelColor
                    // Outline matches MarkupRenderer.contrastColor — i.e. the
                    // same contrasting edge the canvas paints around a mark in
                    // this color. So the tool icon literally previews how the
                    // rendered mark will look on the canvas.
                    let outline: NSColor? = colored
                        ? MarkupRenderer.contrastColor(for: fill) : nil
                    // Filled state flips the rect/ellipse icon between
                    // outlined and solid silhouette to mirror the long-press
                    // choice; everything else stays outlined.
                    let filled: Bool
                    switch t.tool {
                    case .rectangle: filled = self.canvas.rectFilled
                    case .ellipse:   filled = self.canvas.ellipseFilled
                    default: filled = false
                    }
                    return SVGToolIcon.render(svgName, fill: fill, outline: outline,
                                              filled: filled, size: 22)
                }
            }
            toolButtons.append(b)
            toolStack.addArrangedSubview(b)
            // Visual divider between the "image-editing" tools (select / OCR
            // / crop / pixelate) and the "marker" tools (arrow → text).
            if t.tool == .pixelate {
                toolStack.addArrangedSubview(toolbarDivider())
            }
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
        layerStack.spacing = 4

        let colors = ColorPaletteView()
        colors.translatesAutoresizingMaskIntoConstraints = false
        colors.setContentHuggingPriority(.required, for: .horizontal)
        self.colors = colors

        // Stroke / text size: the slider's *own track* is a thin→thick ramp, so
        // it reads as a size control with no separate label needed.
        let slider = RampSlider(value: 4, minValue: 1, maxValue: 30,
                                target: self, action: #selector(widthChanged(_:)))
        slider.isContinuous = true
        slider.toolTip = "Stroke / text size"
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 104).isActive = true
        slider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        self.widthSlider = slider

        // Canvas background fill (shows wherever the canvas has grown past the
        // snapshot). Labelled so it reads as the canvas-color control, not a swatch.
        let bgLabel = NSTextField(labelWithString: "Canvas")
        bgLabel.font = .systemFont(ofSize: 11, weight: .medium)
        bgLabel.textColor = .secondaryLabelColor
        bgLabel.toolTip = "Canvas background color"
        let bgWell = NSColorWell()
        bgWell.color = document.backgroundColor.nsColor
        bgWell.target = self
        bgWell.action = #selector(bgColorChanged(_:))
        bgWell.toolTip = "Canvas background color"
        bgWell.translatesAutoresizingMaskIntoConstraints = false
        bgWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        bgWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        self.bgWell = bgWell
        let bgGroup = NSStackView(views: [bgLabel, bgWell])
        bgGroup.orientation = .horizontal
        bgGroup.spacing = 6

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyFlattened))
        copyButton.bezelStyle = .rounded

        let sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        self.sizeLabel = sizeLabel

        // A leading spacer so the first divider/tool clears the floating window
        // buttons (whose right edge sits ~74pt in).
        let trafficSpacer = NSView()
        trafficSpacer.translatesAutoresizingMaskIntoConstraints = false
        trafficSpacer.widthAnchor.constraint(equalToConstant: 66).isActive = true

        // Groups separated by hairline vertical dividers, in the order:
        // window buttons │ tools │ layer │ colors │ size │ canvas color.
        let palette = NSStackView(views: [
            trafficSpacer,
            toolbarDivider(), toolStack,
            toolbarDivider(), layerStack,
            toolbarDivider(), colors,
            toolbarDivider(), slider,
            toolbarDivider(), bgGroup,
            NSView(), sizeLabel, copyButton,
        ])
        palette.orientation = .horizontal
        palette.alignment = .centerY
        palette.spacing = 12
        palette.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        palette.translatesAutoresizingMaskIntoConstraints = false

        // --- Canvas ---
        let canvas = CanvasView(document: document)
        self.canvas = canvas
        colors.onPick = { [weak self, weak canvas] c in
            canvas?.setActiveColor(c)
            self?.refreshColoredToolIcons()
        }
        canvas.onSelectionChanged = { [weak self] obj in
            guard let self, let obj else { return }
            let c = obj.kind == .highlighter
                ? (obj.fill ?? .highlighter).nsColor.withAlphaComponent(1)
                : obj.stroke.nsColor
            self.colors.reflect(c)
            self.widthSlider.doubleValue = Double(obj.kind == .text ? obj.fontSize / 5 : obj.lineWidth)
            self.refreshColoredToolIcons()
        }
        canvas.onToolChanged = { [weak self] t in self?.setActiveTool(t) }
        canvas.onMutated = { [weak self] in
            self?.window?.isDocumentEdited = true
            self?.scheduleAutosave()
        }
        canvas.onCanvasResized = { [weak self] in self?.fitCanvas(); self?.updateSizeLabel() }
        canvas.onCropped = { [weak self] in self?.resizeWindowToCanvas(); self?.updateSizeLabel() }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        // Padded backdrop around the canvas card. Dynamic so light mode reads
        // as a light grey instead of the dark surround we use in dark mode.
        scroll.backgroundColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.92, alpha: 1)
        }
        // Zoom-to-fit large captures via plain scroll-view magnification (no
        // custom clip view — that shifted the bounds origin and broke event
        // mapping). Centering + even margins come from dynamic contentInsets,
        // which don't move the bounds origin, so hit-testing stays intact.
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 1
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.canvasMargin, left: Self.canvasMargin,
                                            bottom: Self.canvasMargin, right: Self.canvasMargin)
        scroll.scrollerInsets = NSEdgeInsets(top: -Self.canvasMargin, left: -Self.canvasMargin,
                                             bottom: -Self.canvasMargin, right: -Self.canvasMargin)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scroll

        // An opaque toolbar bar that fully owns the top band and catches every
        // click there — otherwise clicks fall through to the canvas behind it.
        // Uses the dynamic background view so it tracks light/dark mode flips.
        let bar = WindowBackgroundView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(palette)

        // A footer bar seated at the bottom edge (incorporated, matching the top
        // toolbar) — brand, file name, export, share.
        let footer = makeFooter()
        self.footerView = footer

        // Scroll first (behind), bar + footer in front so they win hit-testing.
        container.addSubview(scroll)
        container.addSubview(bar)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 56),

            palette.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            palette.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            palette.topAnchor.constraint(equalTo: bar.topAnchor),
            palette.bottomAnchor.constraint(equalTo: bar.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])

        window.contentView = container
        window.makeFirstResponder(canvas)
        window.delegate = self
        installOutsideClickMonitor()

        if document.baseImage == nil && document.objects.isEmpty {
            installEmptyState(in: container, below: bar)
            window.title = "clipandnote"
        }
    }

    /// The bottom footer, seated flush at the window's bottom edge (a hairline
    /// separates it from the canvas, mirroring the top toolbar): centered brand
    /// mark (links to clipandnote.com), file name, Export menu, and share.
    private func makeFooter() -> NSView {
        // Brand: the clipandnote paperclip mark (same template image used in
        // the menu bar) + wordmark, clickable → clipandnote.com.
        let logo = NSImageView()
        if let url = Bundle.main.url(forResource: "menubarTemplate", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true   // tinted to match label color in both modes
            logo.image = img
        }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 22).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 14).isActive = true
        logo.toolTip = "clipandnote.com"

        let wordmark = NSTextField(labelWithString: "clipandnote")
        wordmark.font = .systemFont(ofSize: 12, weight: .semibold)
        wordmark.textColor = .labelColor
        wordmark.toolTip = "clipandnote.com"

        let brand = NSStackView(views: [logo, wordmark])
        brand.orientation = .horizontal
        brand.spacing = 6
        brand.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openWebsite)))
        brand.toolTip = "clipandnote.com"

        // File name (the generated snapshot title until the doc is saved).
        let nameLabel = NSTextField(labelWithString: snapshotTitle)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.fileNameLabel = nameLabel

        // Export — a labelled pull-down so it never reads as "import".
        let exportButton = NSButton(title: "Export", target: self,
                                    action: #selector(exportButtonClicked(_:)))
        exportButton.bezelStyle = .texturedRounded
        exportButton.controlSize = .small
        exportButton.toolTip = "Export as PNG, PDF, or SVG"

        // System share.
        let shareButton = NSButton(
            image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
            target: self, action: #selector(shareButtonClicked(_:)))
        shareButton.bezelStyle = .texturedRounded
        shareButton.controlSize = .small
        shareButton.imageScaling = .scaleProportionallyDown
        shareButton.toolTip = "Share…"

        let stack = NSStackView(views: [brand, notchDivider(), nameLabel, notchDivider(),
                                        exportButton, shareButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let footer = WindowBackgroundView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        topLine.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(topLine)
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            topLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: footer.topAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            stack.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 12),
        ])
        updateFileNameLabel()
        return footer
    }

    private func notchDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://clipandnote.com") { NSWorkspace.shared.open(url) }
    }

    @objc private func exportButtonClicked(_ sender: NSButton) { showExportMenu(from: sender) }
    @objc private func shareButtonClicked(_ sender: NSButton) { shareDocument(from: sender) }

    private func updateFileNameLabel() {
        fileNameLabel?.stringValue = fileURL?.deletingPathExtension().lastPathComponent
            ?? snapshotTitle
    }

    private func showExportMenu(from view: NSView) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Export as PNG…", action: #selector(exportPNG(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Export as PDF…", action: #selector(exportPDF(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Export as SVG…", action: #selector(exportSVG(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func shareDocument(from view: NSView) {
        // Share the flattened image (works whether or not the doc is saved).
        guard let image = canvas.flatten() else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func windowWillClose(_ notification: Notification) {
        autosaveNow()
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    /// Drop the canvas selection when the user clicks the grey backdrop
    /// around the canvas. The selected object(s) lose focus so the next copy
    /// / share / export picks up the whole markup, but the active tool stays
    /// put — useful when you've drawn an arrow, want to capture it cleanly,
    /// and then keep drawing more arrows without round-tripping through the
    /// Select tool.
    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  event.window === self.window,
                  let scroll = self.scrollView,
                  let canvas = self.canvas
            else { return event }
            let winPoint = event.locationInWindow
            let scrollRectInWin = scroll.convert(scroll.bounds, to: nil)
            guard scrollRectInWin.contains(winPoint) else { return event }
            // Inside the canvas card — let normal mouseDown handling run.
            let canvasPoint = canvas.convert(winPoint, from: nil)
            let canvasRect = CGRect(origin: .zero, size: canvas.document.canvasSize)
            if canvasRect.contains(canvasPoint) { return event }
            canvas.deselectAll()
            return nil
        }
    }

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
            zone.bottomAnchor.constraint(equalTo: footerView.topAnchor),
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
        updateFileNameLabel()
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

    /// Tap the ▼ on any tunable tool: opacity slider (10–100%). For
    /// highlighter the slider edits canvas.highlighterOpacity so picking it
    /// up later restores its Skitch-style 0.38 baseline; every other tool
    /// edits canvas.strokeOpacity. Rect / ellipse / text also get their
    /// non-scalar option (outline-vs-filled / font family) above the slider
    /// so they don't lose that choice.
    private func showOpacitySlider(from button: ToolButton) {
        let tool = button.tool
        let isHighlighter = (tool == .highlighter)
        let accessory: NSView? = {
            switch tool {
            case .rectangle, .ellipse: return makeShapeStyleAccessory(for: tool)
            case .text:                return makeFontFamilyAccessory()
            default:                   return nil
            }
        }()
        toolValuePopover.show(from: button, config: .init(
            label: "Opacity", unit: "%", range: 10...100,
            value: { [weak self] in
                guard let self else { return 100 }
                return Double(isHighlighter
                    ? self.canvas.highlighterOpacity
                    : self.canvas.strokeOpacity) * 100
            },
            onChange: { [weak self] v in
                guard let self else { return }
                let a = CGFloat(v / 100)
                if isHighlighter { self.canvas.highlighterOpacity = a }
                else             { self.canvas.strokeOpacity = a }
                self.toolButtons.forEach { $0.refreshIcon() }
            },
            onCommit: nil,
            isInteger: true), accessory: accessory)
    }

    /// Outline-vs-filled segmented control used as the rect / ellipse popover
    /// accessory — same behaviour the old long-press menu had.
    private func makeShapeStyleAccessory(for tool: Tool) -> NSView {
        let isFilled = (tool == .rectangle) ? canvas.rectFilled : canvas.ellipseFilled
        let seg = NSSegmentedControl(labels: ["Outline", "Filled"],
                                     trackingMode: .selectOne,
                                     target: self,
                                     action: #selector(accessoryShapeStyleChanged(_:)))
        seg.selectedSegment = isFilled ? 1 : 0
        seg.segmentDistribution = .fillEqually
        seg.tag = (tool == .rectangle) ? 0 : 1
        seg.controlSize = .small
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return seg
    }

    @objc private func accessoryShapeStyleChanged(_ sender: NSSegmentedControl) {
        let filled = (sender.selectedSegment == 1)
        if sender.tag == 0 { canvas.rectFilled = filled } else { canvas.ellipseFilled = filled }
        toolButtons.forEach { $0.refreshIcon() }
    }

    /// Font-family dropdown used as the text popover accessory — each item
    /// rendered in its own typeface so picking is visual.
    private func makeFontFamilyAccessory() -> NSView {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.controlSize = .small
        picker.addItem(withTitle: "System Font")
        picker.lastItem?.representedObject = ""
        picker.menu?.addItem(.separator())
        let currentFamily = canvas.fontName ?? ""
        for family in NSFontManager.shared.availableFontFamilies {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.representedObject = family
            if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: f])
            }
            picker.menu?.addItem(item)
            if family == currentFamily { picker.select(item) }
        }
        picker.target = self
        picker.action = #selector(accessoryFontFamilyChanged(_:))
        picker.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return picker
    }

    @objc private func accessoryFontFamilyChanged(_ sender: NSPopUpButton) {
        let family = sender.selectedItem?.representedObject as? String ?? ""
        canvas.setActiveFont(family.isEmpty ? nil : family)
    }

    /// Tap the ▼ on the text tool: pick a font family.
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

    /// Press-and-hold the rectangle / ellipse buttons: pick outline or filled
    /// for the *next* shape drawn. (Existing marks aren't retroactively
    /// changed.) The two options are presented as pictograms — the same SVG
    /// rendered in both styles — so you pick the shape that matches the look
    /// you want.
    private func showShapeStyleMenu(for tool: Tool, from button: ToolButton) {
        let isFilled = (tool == .rectangle) ? canvas.rectFilled : canvas.ellipseFilled
        guard let svgName = Self.svgIconName(for: tool) else { return }

        let outlineImg = SVGToolIcon.render(svgName, fill: .labelColor, outline: nil,
                                            filled: false, size: 22)
        let filledImg  = SVGToolIcon.render(svgName, fill: .labelColor, outline: nil,
                                            filled: true,  size: 22)

        let menu = NSMenu()
        let outline = NSMenuItem(title: "Outline",
                                 action: #selector(setShapeStyle(_:)), keyEquivalent: "")
        outline.target = self; outline.tag = 0; outline.representedObject = tool
        outline.image = outlineImg
        outline.state = isFilled ? .off : .on
        menu.addItem(outline)

        let filled = NSMenuItem(title: "Filled",
                                action: #selector(setShapeStyle(_:)), keyEquivalent: "")
        filled.target = self; filled.tag = 1; filled.representedObject = tool
        filled.image = filledImg
        filled.state = isFilled ? .on : .off
        menu.addItem(filled)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func setShapeStyle(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? Tool else { return }
        let filled = (sender.tag == 1)
        switch tool {
        case .rectangle: canvas.rectFilled = filled
        case .ellipse:   canvas.ellipseFilled = filled
        default: break
        }
        pickTool(tool)
        refreshColoredToolIcons()
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.setActiveWidth(CGFloat(sender.doubleValue))
    }

    @objc private func bgColorChanged(_ sender: NSColorWell) {
        canvas.setBackgroundColor(sender.color)
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
        updateFileNameLabel()
    }

    @objc func save(_ sender: Any?) {
        if let url = fileURL { write(to: url) } else { saveAs(sender) }
    }

    @objc func saveAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.canDocument]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent
            ?? snapshotTitle) + ".\(CanFile.ext)"
        applySaveDirectory(to: panel)
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.write(to: url)
        }
    }

    /// Open the panel in the user's chosen save folder, if any (Preferences ▸
    /// Save markups to). Falls back to the system default when unset/invalid.
    private func applySaveDirectory(to panel: NSSavePanel) {
        if let dir = AppSettings.shared.saveDirectory { panel.directoryURL = dir }
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
        applySaveDirectory(to: panel)
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
        updateFileNameLabel()
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
        DispatchQueue.main.async { [weak self] in
            self?.resizeWindowToCanvas(); self?.updateSizeLabel(); self?.positionTrafficLights()
        }
    }

    /// Vertically center the close/minimize/zoom buttons in the tall toolbar band
    /// (the window uses fullSizeContentView, so they'd otherwise sit jammed at the
    /// very top). Gives them room to breathe, like Preview's unified toolbar.
    private func positionTrafficLights() {
        guard let window = window else { return }
        let bar: CGFloat = 56
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }
        let pitch = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.minX : 20
        let leftInset: CGFloat = 20
        for (i, b) in buttons.enumerated() {
            let y = container.bounds.height - bar / 2 - b.frame.height / 2
            b.setFrameOrigin(NSPoint(x: leftInset + CGFloat(i) * pitch, y: y))
        }
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
        let contentH = min(max(canvasSize.height + 56 + margin * 2, 360), maxH)
        let newFrame = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: contentW, height: contentH))
        var frame = window.frame
        // Keep the top-left corner anchored as the window grows/shrinks.
        let top = frame.maxY
        frame.size = newFrame.size
        frame.origin.y = top - newFrame.size.height
        window.setFrame(frame, display: true, animate: false)
        window.center()
        fitCanvas()
    }

    /// Scale the canvas so the *whole* thing fits the viewport with an even
    /// margin, and center it. Large captures shrink to fit instead of running
    /// edge-to-edge; small ones stay at 1:1. Magnification keeps mouse events
    /// correctly mapped, and dynamic insets center the (scaled) canvas.
    func fitCanvas() {
        guard let scroll = scrollView else { return }
        // The viewport is the clip's frame (insets are part of it).
        let viewport = scroll.contentView.frame.size
        guard viewport.width > 1, viewport.height > 1 else { return }
        let margin = Self.canvasMargin
        let canvasSize = canvas.document.canvasSize
        let availW = max(viewport.width - margin * 2, 1)
        let availH = max(viewport.height - margin * 2, 1)
        let scale = min(1, min(availW / canvasSize.width, availH / canvasSize.height))
        scroll.magnification = max(scale, scroll.minMagnification)

        // Center the scaled canvas by padding the slack with insets (never less
        // than the margin). Insets don't shift the bounds origin, so events stay
        // mapped correctly — unlike a centering clip view.
        let scaledW = canvasSize.width * scroll.magnification
        let scaledH = canvasSize.height * scroll.magnification
        let insetX = max(margin, (viewport.width - scaledW) / 2)
        let insetY = max(margin, (viewport.height - scaledH) / 2)
        scroll.contentInsets = NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        scroll.scrollerInsets = NSEdgeInsets(top: -insetY, left: -insetX, bottom: -insetY, right: -insetX)
    }

    func windowDidResize(_ notification: Notification) {
        fitCanvas()
        positionTrafficLights()
    }

    private func updateSizeLabel() {
        let s = canvas.document.canvasSize
        sizeLabel?.stringValue = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        bgWell?.color = canvas.document.backgroundColor.nsColor
    }
}

/// A horizontal slider whose track *is* a thin→thick wedge, so it reads as a
/// size control on its own (no separate ramp icon needed).
final class RampSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { RampSliderCell.self }
        set { }
    }
}

final class RampSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let view = controlView else { return }
        let midY = view.bounds.midY
        let leftH: CGFloat = 2
        let rightH = min(view.bounds.height - 2, 13)
        let wedge = NSBezierPath()
        wedge.move(to: NSPoint(x: rect.minX, y: midY - leftH / 2))
        wedge.line(to: NSPoint(x: rect.maxX, y: midY - rightH / 2))
        wedge.line(to: NSPoint(x: rect.maxX, y: midY + rightH / 2))
        wedge.line(to: NSPoint(x: rect.minX, y: midY + leftH / 2))
        wedge.close()
        NSColor.tertiaryLabelColor.setFill()
        wedge.fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d = min(knobRect.width, knobRect.height) - 1
        let r = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        let knob = NSBezierPath(ovalIn: r)
        NSColor.controlAccentColor.setFill()
        knob.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        knob.lineWidth = 1
        knob.stroke()
    }
}
