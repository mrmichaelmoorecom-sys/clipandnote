import AppKit

/// A click-to-record keyboard-shortcut field. Click it, press a combo (must
/// include a modifier), and it captures the shortcut. Escape cancels.
final class ShortcutRecorderView: NSView {
    var shortcut: Shortcut { didSet { needsDisplay = true } }
    var onChange: ((Shortcut) -> Void)?

    private var recording = false { didSet { needsDisplay = true } }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 130, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let text = recording ? "Type a shortcut…"
            : (shortcut.isNone ? "Click to record" : shortcut.display)
        let color = recording ? NSColor.controlAccentColor
            : (shortcut.isNone ? NSColor.secondaryLabelColor : NSColor.labelColor)
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ])
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                           y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        capture(event)
    }

    /// Intercept key-equivalents (⌘-combos) while recording so they become the
    /// shortcut instead of triggering a menu item.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {                 // Esc cancels
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !mods.isEmpty, !key.isEmpty else { NSSound.beep(); return }
        shortcut = Shortcut(keyCode: event.keyCode, modifiers: mods.rawValue, key: key)
        recording = false
        window?.makeFirstResponder(nil)
        onChange?(shortcut)
    }
}
