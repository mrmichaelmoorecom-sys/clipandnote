import AppKit

/// The snapshot commands exposed in the menu bar.
enum CaptureKind {
    case crosshair          // drag-select a region (custom overlay)
    case previousArea       // re-shoot the last region, non-interactively
    case fullscreen         // all displays
    case window             // interactive window picker
    case menu               // countdown, then auto-grab the open menu + submenus
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
            // A countdown gives you time to open the menu; at zero we find the
            // open menu's window(s) and grab exactly those — no click, so the
            // menu is never dismissed (clicking would close it).
            CountdownHUD.run(seconds: AppSettings.shared.timedDelaySeconds,
                             hint: "open the menu (and any submenu)") { [weak self] in
                self?.shootOpenMenus(completion: completion)
            }
        }
    }

    // MARK: Auto-grab the open menu

    /// Capture whatever menu(s) are open right now, by window. All cascading
    /// menu windows (a menu plus any open submenus) sit at the pop-up-menu
    /// window level, so we union their bounds and grab that one rectangle. No
    /// interactive click is involved, so the menu stays open through the grab.
    private func shootOpenMenus(completion: @escaping (NSImage?) -> Void) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        // Menus/submenus render at the pop-up-menu window level (101); status
        // items live below (≤25) and our countdown HUD above (screen-saver,
        // 1000). Accept the menu level up to — but not including — the HUD's.
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let hudLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

        func bounds(_ w: [String: Any]) -> CGRect? {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict) else { return nil }
            return r
        }
        func owner(_ w: [String: Any]) -> String { w[kCGWindowOwnerName as String] as? String ?? "" }
        func layer(_ w: [String: Any]) -> Int { w[kCGWindowLayer as String] as? Int ?? 0 }

        // Every open menu / submenu window.
        let menus = info.filter { layer($0) >= menuLevel && layer($0) < hudLevel }
            .compactMap { bounds($0) }
            .filter { $0.width >= 8 && $0.height >= 8 }

        if let union = menus.dropFirst().reduce(menus.first, { $0?.union($1) }) {
            shootRect(union, completion: completion)
            return
        }

        // Nothing open — fall back to the frontmost real window (not fullscreen).
        if let front = info.first(where: {
            layer($0) == 0 && owner($0) != "clipandnote"
                && (bounds($0)?.width ?? 0) >= 40 && (bounds($0)?.height ?? 0) >= 40
        }), let id = front[kCGWindowNumber as String] as? Int {
            shoot(["-x", "-l", String(id)], completion: completion)
            return
        }
        completion(nil)
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
