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
