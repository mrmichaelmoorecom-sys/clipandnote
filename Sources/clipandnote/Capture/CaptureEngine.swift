import AppKit

/// The snapshot commands exposed in the menu bar.
enum CaptureKind {
    case crosshair          // drag-select a region (custom overlay)
    case previousArea       // re-shoot the last region, non-interactively
    case timedCrosshair     // countdown, then drag-select a region
    case fullscreen         // all displays
    case window             // interactive window picker
    case menu               // countdown (open a menu), then full-screen grab
}

/// Captures the screen. Region modes use `RegionSelectionOverlay` so the chosen
/// rectangle is known and can be replayed by "Previous Snapshot Area"; the rest
/// shell out to the system `screencapture` tool.
final class CaptureEngine {
    /// The last region captured, in screencapture coordinates. nil until the
    /// first region capture records one.
    private(set) var lastRegion: CGRect?

    func capture(_ kind: CaptureKind, completion: @escaping (NSImage?) -> Void) {
        switch kind {
        case .crosshair:
            selectThenShoot(delay: 0, completion: completion)
        case .timedCrosshair:
            // Region overlay after a delay, so you can set up a hover/transient
            // state first, then drag the region.
            selectThenShoot(delay: AppSettings.shared.timedDelaySeconds, completion: completion)
        case .previousArea:
            if let r = lastRegion {
                shootRect(r, completion: completion)
            } else {
                selectThenShoot(delay: 0, completion: completion)   // nothing stored yet
            }
        case .fullscreen:
            shoot(["-x"], completion: completion)
        case .window:
            shoot(["-x", "-i", "-W"], completion: completion)
        case .menu:
            // Distinct from Timed (which drags a region): after a delay to open
            // the target menu, capture in window/menu selection mode (-W) so a
            // click grabs the whole menu or window, with its shadow.
            let delay = max(AppSettings.shared.timedDelaySeconds, 3)
            shoot(["-x", "-T", String(delay), "-W"], completion: completion)
        }
    }

    // MARK: Region overlay

    private func selectThenShoot(delay: Int, completion: @escaping (NSImage?) -> Void) {
        let begin = {
            RegionSelectionOverlay.selectRegion { [weak self] rect in
                guard let rect else { completion(nil); return }   // cancelled
                self?.lastRegion = rect
                self?.shootRect(rect, completion: completion)
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay), execute: begin)
        } else {
            begin()
        }
    }

    private func shootRect(_ r: CGRect, completion: @escaping (NSImage?) -> Void) {
        let rect = "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
        shoot(["-x", "-R", rect], completion: completion)
    }

    // MARK: screencapture

    private func shoot(_ args: [String], completion: @escaping (NSImage?) -> Void) {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipandnote-\(UUID().uuidString).png")
        var argv = args
        argv.append(out.path)

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = argv
            try? proc.run()
            proc.waitUntilExit()

            let image = (try? Data(contentsOf: out)).flatMap { NSImage(data: $0) }
            try? FileManager.default.removeItem(at: out)
            DispatchQueue.main.async { completion(image) }
        }
    }
}
