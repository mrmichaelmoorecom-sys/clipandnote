import AppKit

/// Centers the document view when it's smaller than the viewport, so a snapshot
/// narrower/shorter than the toolbar sits centered rather than pinned top-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let docFrame = doc.frame
        if docFrame.width < rect.width {
            rect.origin.x = floor((docFrame.width - rect.width) / 2)
        }
        if docFrame.height < rect.height {
            rect.origin.y = floor((docFrame.height - rect.height) / 2)
        }
        return rect
    }
}
