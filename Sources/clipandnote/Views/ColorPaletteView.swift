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

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
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
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<allColors.count {
            let s = SwatchView()
            s.onClick = { [weak self] in self?.pick(index: i) }
            swatches.append(s)
            stack.addArrangedSubview(s)
            if i == presets.count - 1 {       // divider between presets and customs
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
                stack.addArrangedSubview(sep)
            }
        }

        well.colorWellStyle = .minimal
        well.color = presets[0]
        well.target = self
        well.action = #selector(wellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 26).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        well.toolTip = "Pick a custom color — it’s saved to an empty slot"
        stack.addArrangedSubview(well)

        // Eyedropper: sample a color from anywhere on screen into a custom slot.
        let dropper = IconButton(symbolName: "eyedropper",
                                 tooltip: "Sample a color from anywhere on screen")
        dropper.onClick = { [weak self] in self?.sampleColor() }
        dropper.translatesAutoresizingMaskIntoConstraints = false
        dropper.widthAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(dropper)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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
