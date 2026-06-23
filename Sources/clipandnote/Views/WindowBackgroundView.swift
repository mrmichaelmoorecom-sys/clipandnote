import AppKit

/// An opaque view that fills itself with `NSColor.windowBackgroundColor` every
/// frame, so it tracks dark / light mode flips automatically. We can't just
/// stash `.windowBackgroundColor.cgColor` on a CALayer because CGColors are
/// frozen — the layer would keep the old appearance forever.
final class WindowBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
