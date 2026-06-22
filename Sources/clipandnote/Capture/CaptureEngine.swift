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
            // Snapshot the window list *before* the HUD appears; anything that
            // opens during the countdown is the menu / popover / panel the user
            // is targeting. This works for plain NSMenu, NSPopover, and the
            // borderless panels apps like clipandcue and Dropbox use — none of
            // them share a single window level, so a level-based filter misses
            // them. A diff is implementation-agnostic.
            let baseline = onScreenWindowIDs()
            CountdownHUD.run(seconds: AppSettings.shared.timedDelaySeconds,
                             hint: "open the menu (and any submenu)") { [weak self] in
                self?.shootNewlyOpened(since: baseline, completion: completion)
            }
        }
    }

    // MARK: Auto-grab the open menu / popover / panel

    private func onScreenWindowIDs() -> Set<Int> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    /// Find every window that appeared *during* the countdown (i.e. wasn't in
    /// `baseline`), union their bounds, and capture that rectangle. Captures
    /// menus, popovers, dropdowns and custom panels alike — whatever the user
    /// opened — without a click that would dismiss them. Falls back to the
    /// pop-up-menu window level if nothing new was detected (rare).
    private func shootNewlyOpened(since baseline: Set<Int>,
                                  completion: @escaping (NSImage?) -> Void) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let hudLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))   // 24

        // System chrome owners we don't want to capture even if they animate in.
        let chromeOwners: Set<String> = [
            "Window Server", "Dock", "Control Center", "NotificationCenter",
            "WindowManager", "Spotlight", "TextInputMenuAgent",
        ]

        func id(_ w: [String: Any]) -> Int? { w[kCGWindowNumber as String] as? Int }
        func bounds(_ w: [String: Any]) -> CGRect? {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict) else { return nil }
            return r
        }
        func owner(_ w: [String: Any]) -> String { w[kCGWindowOwnerName as String] as? String ?? "" }
        func layer(_ w: [String: Any]) -> Int { w[kCGWindowLayer as String] as? Int ?? 0 }

        let newRects: [CGRect] = info.compactMap { w in
            guard let wid = id(w), !baseline.contains(wid) else { return nil }
            let l = layer(w), o = owner(w)
            // Exclude clipandnote's own HUD, the system menu bar itself, anything
            // above the HUD, and known chrome owners.
            guard o != "clipandnote",
                  l < hudLevel,
                  l != mainMenuLevel,
                  !chromeOwners.contains(o) else { return nil }
            guard let r = bounds(w), r.width >= 8, r.height >= 8 else { return nil }
            return r
        }

        if let union = newRects.dropFirst().reduce(newRects.first, { $0?.union($1) }) {
            shootRect(union, completion: completion)
            return
        }

        // Nothing new appeared — try the legacy pop-up-menu level (in case a
        // menu was already open before triggering). No frontmost-window
        // fallback: capturing the wrong window is worse than no capture.
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let menus = info.filter { layer($0) >= menuLevel && layer($0) < hudLevel }
            .compactMap { bounds($0) }
            .filter { $0.width >= 8 && $0.height >= 8 }
        if let union = menus.dropFirst().reduce(menus.first, { $0?.union($1) }) {
            shootRect(union, completion: completion)
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
