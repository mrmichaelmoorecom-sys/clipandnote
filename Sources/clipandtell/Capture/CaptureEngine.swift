import AppKit

/// The snapshot commands exposed in the menu bar. These map onto macOS's
/// `screencapture` tool for v0.1; a custom selection overlay (needed for pixel-
/// accurate "Previous Snapshot Area" and in-app crosshair styling) replaces the
/// interactive modes in a later phase.
enum CaptureKind {
    case crosshair          // interactive region select
    case previousArea       // re-shoot the last region rect, non-interactively
    case timedCrosshair     // interactive region select after a delay
    case fullscreen         // all displays
    case window             // interactive window picker
    case menu               // delayed interactive — gives you time to open a menu
}

/// Captures the screen via the system `screencapture` binary and hands back an
/// NSImage. Using the CLI means macOS handles the Screen Recording TCC prompt
/// for us and the interactive UIs are pixel-perfect and familiar.
final class CaptureEngine {
    /// The last region rectangle captured (display coordinates), enabling
    /// "Previous Snapshot Area". nil until the first region capture records one.
    private(set) var lastRegion: CGRect?

    /// Capture, then deliver the image on the main queue (nil = user cancelled).
    func capture(_ kind: CaptureKind, completion: @escaping (NSImage?) -> Void) {
        let delay = AppSettings.shared.timedDelaySeconds
        var args = ["-x"]   // -x: no capture sound

        switch kind {
        case .crosshair:
            args += ["-i"]
        case .timedCrosshair:
            args += ["-T", String(delay), "-i"]
        case .menu:
            // Give the user a moment to open a menu, then drag-select over it.
            args += ["-T", String(max(delay, 3)), "-i"]
        case .fullscreen:
            break               // no flag = whole screen(s)
        case .window:
            args += ["-i", "-W"] // interactive window mode
        case .previousArea:
            guard let r = lastRegion else {
                // No prior region yet — fall back to interactive so the user
                // gets a sensible result instead of nothing.
                args += ["-i"]
                break
            }
            let rect = "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))"
            args += ["-R", rect]
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipandtell-\(UUID().uuidString).png")
        args.append(out.path)

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = args
            try? proc.run()
            proc.waitUntilExit()

            let image: NSImage?
            if let data = try? Data(contentsOf: out), let img = NSImage(data: data) {
                image = img
            } else {
                image = nil   // user pressed Esc, or capture produced nothing
            }
            try? FileManager.default.removeItem(at: out)

            DispatchQueue.main.async { completion(image) }
        }
    }
}
