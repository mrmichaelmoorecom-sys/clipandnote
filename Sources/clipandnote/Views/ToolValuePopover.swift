import AppKit

/// A tiny floating popover anchored at a tool button's ▼ — one continuous
/// horizontal slider, with a "tooltip-style" value bubble that floats next to
/// the slider knob *while* the user is dragging and disappears the instant
/// they let go. Used for per-tool width / opacity / size tweaks (highlighter
/// opacity, line width on arrow / line / freehand / shapes, font size on
/// text).
final class ToolValuePopover: NSObject {
    /// Track-on / track-off bracketing of a drag — caller persists the value
    /// onChanged and commits an undo step onCommit.
    struct Config {
        let label: String        // e.g. "Width", "Opacity"
        let unit: String         // e.g. "pt", "%"
        let range: ClosedRange<Double>
        let value: () -> Double          // current value (read every open)
        let onChange: (Double) -> Void   // continuous (every drag tick)
        let onCommit: (() -> Void)?      // once at mouse-up — for undo
        let isInteger: Bool              // formats the bubble as int vs 1-decimal
    }

    private let popover = NSPopover()
    private var slider: NSSlider!
    private var bubble: ValueBubble!
    private var cfg: Config!
    private weak var anchor: NSView?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .vibrantDark)
    }

    func show(from button: NSView, config: Config) {
        cfg = config
        anchor = button
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 26))

        slider = NSSlider(value: config.value(),
                          minValue: config.range.lowerBound,
                          maxValue: config.range.upperBound,
                          target: self, action: #selector(sliderChanged(_:)))
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        let vc = NSViewController()
        vc.view = host
        popover.contentViewController = vc
        popover.contentSize = host.frame.size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)

        // Bubble is owned by the popover's window so it can float a few pixels
        // above the knob — putting it inside the popover would clip it.
        bubble = ValueBubble(format: formatted)
    }

    @objc private func sliderChanged(_ s: NSSlider) {
        cfg.onChange(s.doubleValue)
        // NSSlider's tracking-event lifecycle: continuous = true by default
        // for sendAction, so we get a stream of -changed events plus a final
        // one when the mouse comes up. We show the bubble while the mouse is
        // pressed and hide it on release; AppKit conveniently exposes that
        // via the current NSApp event.
        let event = NSApp.currentEvent
        let isTracking = event.map { $0.type == .leftMouseDragged || $0.type == .leftMouseDown } ?? false
        if isTracking {
            bubble.show(near: s, text: formatted(s.doubleValue))
        } else {
            bubble.hide()
            cfg.onCommit?()
        }
    }

    private func formatted(_ v: Double) -> String {
        let valueText: String
        if cfg.isInteger {
            valueText = "\(Int(v.rounded()))"
        } else {
            valueText = String(format: "%.1f", v)
        }
        return "\(valueText)\(cfg.unit)"
    }
}

/// A small dark rounded label that floats just above the slider knob during a
/// drag. We render it as its own borderless window so it can sit outside the
/// popover's bounds without being clipped.
private final class ValueBubble {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let bg = NSView()
    init(format: @escaping (Double) -> String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 22),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        window.ignoresMouseEvents = true
        let container = NSView(frame: window.contentLayoutRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.85).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -5),
        ])
        window.contentView = container
        _ = bg ; _ = format
    }
    func show(near slider: NSSlider, text: String) {
        label.stringValue = text
        label.sizeToFit()
        let w = max(label.frame.width + 16, 36)
        // Position above the slider's knob. NSSlider's knob position isn't
        // public; we approximate with the slider frame fraction.
        let frac = (slider.doubleValue - slider.minValue) /
                   max(0.0001, slider.maxValue - slider.minValue)
        let trackInset: CGFloat = 8
        let knobX = trackInset + CGFloat(frac) * (slider.bounds.width - trackInset * 2)
        let pointInWindow = slider.convert(NSPoint(x: knobX, y: slider.bounds.midY), to: nil)
        guard let screenOrigin = slider.window?.convertPoint(toScreen: pointInWindow) else { return }
        window.setFrame(NSRect(x: screenOrigin.x - w / 2,
                                y: screenOrigin.y + 18,
                                width: w, height: 22),
                        display: true)
        if !window.isVisible { window.orderFront(nil) }
    }
    func hide() { window.orderOut(nil) }
}
