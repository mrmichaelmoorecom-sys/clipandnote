import AppKit

/// A single color swatch. A plain view (not NSButton) so its *entire* 22×22 area
/// is clickable — a borderless NSButton with no title/image reports no hit in its
/// blank region, which silently breaks clicks.
final class SwatchView: NSView {
    var onClick: (() -> Void)?
    private(set) var color: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 13, height: 13) }
    override func mouseDown(with event: NSEvent) {
        if color != nil { onClick?() }
    }

    func update(color: NSColor?, selected: Bool) {
        self.color = color
        let isEmpty = color == nil
        layer?.backgroundColor = (color ?? .clear).cgColor
        layer?.borderWidth = selected ? 2.5 : 1
        layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor
            : (isEmpty ? NSColor.tertiaryLabelColor.cgColor : NSColor.separatorColor.cgColor)
        toolTip = isEmpty ? "Empty — use the picker to add a color" : nil
    }
}

/// A compact color palette: a row of preset swatches, a few initially-empty
/// custom slots, and an ever-present color picker. Picking a custom color from
/// the picker fills the next empty slot so your colors accumulate and stay reusable.
final class ColorPaletteView: NSView {

    /// Fired when the user chooses a color (preset, saved custom, or the picker).
    var onPick: ((NSColor) -> Void)?

    private let presets: [NSColor] = [
        .black, RGBAColor.red.nsColor, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .systemPurple, .white,
    ]
    private var customColors: [NSColor?] = [nil, nil, nil, nil]
    private var customRoll = 0

    private var swatches: [SwatchView] = []        // presets first, then customs
    private let well = NSColorWell()
    private let hexField = NSTextField()
    private var selected: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private var allColors: [NSColor?] { presets.map { Optional($0) } + customColors }

    private func build() {
        // Two stacked rows of swatches so the colour palette takes half the
        // toolbar-width footprint without making the bar taller. Layout:
        //   row 1: 6 presets (red / orange / yellow / green / blue / purple)
        //   row 2: 2 presets (black / white) + 4 custom slots
        //   side column: NSColorWell picker + eyedropper button
        let cols = 6
        let row1 = NSStackView(); row1.orientation = .horizontal; row1.spacing = 3
        let row2 = NSStackView(); row2.orientation = .horizontal; row2.spacing = 3

        let all = allColors
        for i in 0..<all.count {
            let s = SwatchView()
            s.onClick = { [weak self] in self?.pick(index: i) }
            swatches.append(s)
            (i < cols ? row1 : row2).addArrangedSubview(s)
        }

        let grid = NSStackView(views: [row1, row2])
        grid.orientation = .vertical
        grid.spacing = 2
        grid.alignment = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        // Side controls: small picker + eyedropper, stacked vertically to match
        // the two-row grid height.
        well.colorWellStyle = .minimal
        well.color = presets[0]
        well.target = self
        well.action = #selector(wellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 13).isActive = true
        well.heightAnchor.constraint(equalToConstant: 13).isActive = true
        well.toolTip = "Pick a custom color — it’s saved to an empty slot"

        let dropper = IconButton(symbolName: "eyedropper",
                                 tooltip: "Sample a color from anywhere on screen")
        dropper.onClick = { [weak self] in self?.sampleColor() }
        dropper.translatesAutoresizingMaskIntoConstraints = false
        dropper.widthAnchor.constraint(equalToConstant: 13).isActive = true
        dropper.heightAnchor.constraint(equalToConstant: 13).isActive = true

        // Editable hex value — type "#RRGGBB" (or "RRGGBB") and press Return to
        // set the active colour precisely. Reflects the selected colour live.
        hexField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hexField.placeholderString = "#000000"
        hexField.alignment = .left
        hexField.isBezeled = true
        hexField.bezelStyle = .roundedBezel
        hexField.controlSize = .small
        hexField.focusRingType = .none
        hexField.target = self
        hexField.action = #selector(hexEntered(_:))
        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.widthAnchor.constraint(equalToConstant: 68).isActive = true
        hexField.toolTip = "Hex colour — type #RRGGBB and press Return"

        // Picker well + eyedropper side-by-side (original layout), with the hex
        // field next to them. Extra gap between the well and the eyedropper so
        // they don't crowd.
        let sideCol = NSStackView(views: [well, dropper, hexField])
        sideCol.orientation = .horizontal
        sideCol.spacing = 8
        sideCol.alignment = .centerY
        sideCol.setCustomSpacing(13, after: well)
        sideCol.translatesAutoresizingMaskIntoConstraints = false

        // Wider gap between the preset grid and the custom-colour tools so the
        // tool group reads as its own section rather than a 7th column of the
        // swatch grid.
        let outer = NSStackView(views: [grid, sideCol])
        outer.orientation = .horizontal
        outer.spacing = 16
        outer.alignment = .centerY
        outer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        selected = presets[0]
        refresh()
    }

    // MARK: Actions

    private func pick(index: Int) {
        guard index < allColors.count, let c = allColors[index] else { return }
        selected = c
        refresh()
        onPick?(c)
    }

    @objc private func wellChanged(_ w: NSColorWell) {
        let c = w.color
        addCustom(c)
        selected = c
        refresh()
        onPick?(c)
    }

    /// Pick a color from anywhere on screen with the system magnifier loupe.
    private func sampleColor() {
        NSColorSampler().show { [weak self] color in
            guard let self, let color else { return }
            self.addCustom(color)
            self.selected = color
            self.well.color = color
            self.refresh()
            self.onPick?(color)
        }
    }

    /// Reflect an externally-chosen color (e.g. the selected object's color).
    func reflect(_ color: NSColor) {
        addCustom(color)
        selected = color
        well.color = color
        refresh()
    }

    private func addCustom(_ c: NSColor) {
        if (presets + customColors.compactMap { $0 }).contains(where: { colorsEqual($0, c) }) { return }
        customColors[customRoll % customColors.count] = c
        customRoll += 1
        refresh()
    }

    @objc private func hexEntered(_ sender: NSTextField) {
        guard let c = Self.color(fromHex: sender.stringValue) else {
            // Invalid input — restore the field to the current selection.
            if let sel = selected { sender.stringValue = Self.hexString(sel) }
            return
        }
        addCustom(c)
        selected = c
        well.color = c
        refresh()
        onPick?(c)
    }

    private func refresh() {
        let all = allColors
        for (i, s) in swatches.enumerated() {
            let c = all[i]
            let isSel = c != nil && selected != nil && colorsEqual(c!, selected!)
            s.update(color: c, selected: isSel)
        }
        // Keep the hex field showing the selected colour (unless it's being
        // edited, so we don't yank the text out from under the cursor).
        if let sel = selected, window?.firstResponder !== hexField.currentEditor() {
            hexField.stringValue = Self.hexString(sel)
        }
    }

    /// "#RRGGBB" for a colour (sRGB).
    static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parse "#RRGGBB" / "RRGGBB" / "#RGB" → NSColor; nil if malformed.
    static func color(fromHex raw: String) -> NSColor? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }   // #RGB → #RRGGBB
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let e: CGFloat = 0.01
        return abs(x.redComponent - y.redComponent) < e
            && abs(x.greenComponent - y.greenComponent) < e
            && abs(x.blueComponent - y.blueComponent) < e
    }
}
