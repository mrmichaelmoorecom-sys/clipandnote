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
        RGBAColor.red.nsColor, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white,
    ]
    private var customColors: [NSColor?] = [nil, nil, nil, nil]
    private var customRoll = 0

    private var swatches: [SwatchView] = []        // presets first, then customs
    private let well = NSColorWell()
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

        // Picker + eyedropper sit side-by-side as a single row (not stacked) so
        // they read as two peer controls instead of a tall pill. Big gap
        // between them — a few times the 13pt control width — so they read
        // as clearly distinct controls rather than a paired pill.
        let sideCol = NSStackView(views: [well, dropper])
        sideCol.orientation = .horizontal
        sideCol.spacing = 28
        sideCol.alignment = .centerY
        sideCol.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [grid, sideCol])
        outer.orientation = .horizontal
        outer.spacing = 6
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

    private func refresh() {
        let all = allColors
        for (i, s) in swatches.enumerated() {
            let c = all[i]
            let isSel = c != nil && selected != nil && colorsEqual(c!, selected!)
            s.update(color: c, selected: isSel)
        }
    }

    private func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let e: CGFloat = 0.01
        return abs(x.redComponent - y.redComponent) < e
            && abs(x.greenComponent - y.greenComponent) < e
            && abs(x.blueComponent - y.blueComponent) < e
    }
}
