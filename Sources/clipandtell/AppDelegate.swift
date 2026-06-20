import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capture = CaptureEngine()
    private var statusController: StatusItemController!
    /// Strong references so editor windows aren't deallocated while open.
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        let sc = StatusItemController()
        sc.onCapture = { [weak self] kind in self?.runCapture(kind) }
        sc.onPickRecent = { [weak self] idx in self?.pasteRecent(idx) }
        sc.onPreferences = { /* Preferences window — next phase. */ }
        statusController = sc

        switch ProcessInfo.processInfo.environment["CLIPANDTELL_DEMO"] {
        case "render": renderDemoAndExit()   // headless: write PNG, quit
        case "1":      openDemo()            // interactive: seed an editor window
        default:       break
        }
    }

    /// Dev-only headless check: render the sample markup to /tmp and exit, so the
    /// renderer can be inspected without launching the full UI.
    private func renderDemoAndExit() {
        let canvas = CanvasView(document: DemoContent.makeDocument())
        if let png = canvas.flatten()?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "/tmp/clipandtell-demo.png"))
            NSLog("clipandtell demo: wrote /tmp/clipandtell-demo.png")
        }
        exit(0)
    }

    /// Dev-only: open an editor seeded with one of every annotation kind.
    private func openDemo() {
        let editor = EditorWindowController(document: DemoContent.makeDocument())
        editors.append(editor)
        editor.show()
    }

    /// Minimal main menu so standard editing shortcuts (paste-as-object, copy,
    /// undo/redo) dispatch through the responder chain into the active canvas.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About clipandtell", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit clipandtell",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        func add(_ title: String, _ sel: String, _ key: String, _ mask: NSEvent.ModifierFlags = .command) {
            let mi = NSMenuItem(title: title, action: Selector((sel)), keyEquivalent: key)
            mi.keyEquivalentModifierMask = mask
            editMenu.addItem(mi)
        }
        add("Undo", "undo:", "z")
        add("Redo", "redo:", "z", [.command, .shift])
        editMenu.addItem(.separator())
        add("Cut", "cut:", "x")
        add("Copy", "copy:", "c")
        add("Paste", "paste:", "v")
        add("Delete", "delete:", "")
        add("Select All", "selectAll:", "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Arrange (z-order) — dispatched through the responder chain to the canvas.
        let arrangeItem = NSMenuItem()
        let arrangeMenu = NSMenu(title: "Arrange")
        func arr(_ title: String, _ sel: String, _ key: String, _ mask: NSEvent.ModifierFlags) {
            let mi = NSMenuItem(title: title, action: Selector((sel)), keyEquivalent: key)
            mi.keyEquivalentModifierMask = mask
            arrangeMenu.addItem(mi)
        }
        arr("Bring to Front", "bringToFront:", "]", [.command, .shift])
        arr("Bring Forward", "bringForward:", "]", [.command])
        arr("Send Backward", "sendBackward:", "[", [.command])
        arr("Send to Back", "sendToBack:", "[", [.command, .shift])
        arrangeItem.submenu = arrangeMenu
        main.addItem(arrangeItem)

        NSApp.mainMenu = main
    }

    private func runCapture(_ kind: CaptureKind) {
        capture.capture(kind) { [weak self] image in
            guard let self, let image else { return }   // nil = user cancelled
            let editor = EditorWindowController(image: image)
            self.editors.append(editor)
            editor.show()
            // Markup history + CloudKit + recents menu wiring lands next phase.
        }
    }

    private func pasteRecent(_ index: Int) {
        // Recents are empty until the history store exists (next phase).
    }

    /// Keep the app alive when the last editor window closes — it lives in the
    /// menu bar, like Skitch's capture-ready state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
