import AppKit

/// NSClipView that catches mouseDown events landing in its empty area (around
/// the canvas card) and grows the canvas to include the click point — so the
/// user can click anywhere in the grey backdrop with a drawing tool active and
/// the canvas stretches out to that spot. Clicks inside the canvas itself are
/// routed normally by AppKit and never reach here. Bounds are deliberately
/// untouched — a previous custom clip view that shifted bounds origin broke
/// canvas hit-testing, so we restrict ourselves to event handling.
final class ExpandingClipView: NSClipView {
    weak var canvas: CanvasView?

    override func mouseDown(with event: NSEvent) {
        guard let canvas = self.canvas else {
            super.mouseDown(with: event); return
        }
        // Select tool has no notion of "draw beyond the edge", so leave the
        // click as a no-op there.
        if canvas.tool == .select {
            super.mouseDown(with: event); return
        }
        let p = canvas.convert(event.locationInWindow, from: nil)
        let bounds = CGRect(origin: .zero, size: canvas.document.canvasSize)
        if bounds.contains(p) {
            // AppKit should have routed inside-canvas clicks to the canvas
            // already; fall through to default just in case.
            super.mouseDown(with: event); return
        }
        canvas.expandToInclude(point: p)
    }
}
