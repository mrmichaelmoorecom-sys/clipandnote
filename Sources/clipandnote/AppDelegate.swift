import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capture = CaptureEngine()
    private let hotkeys = HotkeyManager()
    private var statusController: StatusItemController!
    private var prefsWindow: PreferencesWindowController?
    private var galleryWindow: GalleryWindowController?
    /// Strong references so editor windows aren't deallocated while open.
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Appearance follows the system automatically (NSApp.appearance left nil).
        buildMainMenu()
        let sc = StatusItemController()
        sc.onCapture = { [weak self] kind in self?.runCapture(kind) }
        sc.onPickRecent = { [weak self] idx in self?.pickRecent(idx) }
        sc.onOpenGallery = { [weak self] in self?.openGallery(nil) }
        sc.onPreferences = { [weak self] in self?.openPreferences() }
        statusController = sc

        // Keep the menu-bar "Recent Markups" list in sync with the library.
        MarkupLibrary.shared.onChange = { [weak self] in self?.refreshRecents() }
        refreshRecents()

        // Global capture hotkeys (⌘⌥… by default; customizable in Preferences).
        hotkeys.onCapture = { [weak self] kind in self?.runCapture(kind) }
        hotkeys.reload()

        switch ProcessInfo.processInfo.environment["CLIPANDNOTE_DEMO"] {
        case "render": renderDemoAndExit()                       // headless: write PNG, quit
        case "1":      openDemo(DemoContent.makeDocument())      // seeded editor window
        case "small":  openDemo(DemoContent.makeSmallDocument()) // small snapshot (centering)
        case "name":   nameDemoAndExit()                         // headless: OCR + visual naming
        case "classify": classifyDemoAndExit()                   // headless: visual classifier
        case "canio":  canIOTestAndExit()                        // headless: .can round-trip
        case "export": exportTestAndExit()                       // headless: PNG + PDF export
        case "library": libraryTestAndExit()                     // headless: library add/list/load
        case "gallery": seedAndOpenGallery()                     // seed entries + open the gallery
        default:       break
        }
    }

    /// Dev-only: seed a few library entries and open the gallery to eyeball it.
    private func seedAndOpenGallery() {
        let lib = MarkupLibrary.shared
        if lib.entries.count < 3 {
            let now = Date()
            lib.add(DemoContent.makeDocument(), name: "2026-06-20 14-02 · Account settings", at: now)
            lib.add(DemoContent.makeSmallDocument(), name: "2026-06-20 13-40 · Tiny snapshot", at: now.addingTimeInterval(-60))
            let id = lib.add(DemoContent.makeDocument(), name: "2026-06-20 11-15 · Login error", at: now.addingTimeInterval(-3600))
            lib.setPinned(id, true)
        }
        openGallery(nil)
    }

    /// Dev-only: add a couple of markups to the library, then read them back.
    private func libraryTestAndExit() {
        let lib = MarkupLibrary.shared
        let id1 = lib.add(DemoContent.makeDocument(), name: "Demo A", at: Date())
        let id2 = lib.add(DemoContent.makeSmallDocument(), name: "Demo B", at: Date())
        let recents = lib.recent(10)
        let loaded = lib.document(id1)
        print("LIB entries=\(lib.entries.count) recent=\(recents.map { $0.name }) "
            + "reload=\(loaded?.objects.count ?? -1)objs "
            + "png1=\(lib.flatPNG(id1)?.count ?? 0)b thumb2=\(lib.thumbnail(id2) != nil)")
        // clean up the two test entries so we don't pollute a real library
        lib.delete(id1); lib.delete(id2)
        exit(0)
    }

    /// Dev-only: export the demo to PNG + PDF, and rasterize the PDF to check it.
    private func exportTestAndExit() {
        let doc = DemoContent.makeDocument()
        if let png = MarkupExporter.png(doc, scale: 2) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/clipandnote-export.png"))
            print("PNG bytes=\(png.count)")
        }
        if let pdf = MarkupExporter.pdf(doc) {
            try? pdf.write(to: URL(fileURLWithPath: "/tmp/clipandnote-export.pdf"))
            print("PDF bytes=\(pdf.count)")
            // Rasterize the PDF back to PNG to eyeball orientation/content.
            if let raster = NSImage(data: pdf)?.pngData() {
                try? raster.write(to: URL(fileURLWithPath: "/tmp/clipandnote-export-pdf.png"))
            }
        }
        let svg = SVGExporter.svg(doc)
        try? svg.write(toFile: "/tmp/clipandnote-export.svg", atomically: true, encoding: .utf8)
        print("SVG bytes=\(svg.utf8.count)")
        exit(0)
    }

    /// Dev-only: write the demo to a .can file, read it back, and report fidelity.
    private func canIOTestAndExit() {
        let original = DemoContent.makeDocument()
        let url = URL(fileURLWithPath: "/tmp/clipandnote-test.can")
        do {
            try CanFile.write(original, to: url)
            let loaded = try CanFile.read(url)
            let bytes = (try? Data(contentsOf: url))?.count ?? 0
            print("CANIO objs \(original.objects.count)->\(loaded.objects.count) "
                + "base=\(loaded.baseImage != nil) canvas=\(loaded.canvasSize) "
                + "frame=\(loaded.baseImageFrame) bytes=\(bytes)")
        } catch {
            print("CANIO error: \(error)")
        }
        exit(0)
    }

    /// Dev-only: report whether MobileCLIP loaded and its top labels for the demo.
    private func classifyDemoAndExit() {
        let base = DemoContent.makeBaseImage()
        if let png = base.pngData() { try? png.write(to: URL(fileURLWithPath: "/tmp/clipandnote-base.png")) }
        // Classify the SAVED png so Swift and the Python reference see identical bytes.
        guard let img = NSImage(contentsOfFile: "/tmp/clipandnote-base.png"),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
        let mobileCLIP = MobileCLIPClassifier()
        print("MobileCLIP loaded: \(mobileCLIP != nil)")
        let classifier: VisualClassifier = mobileCLIP ?? VisionClassifier()
        for label in classifier.classify(cg).prefix(5) {
            print(String(format: "  %@  %.3f", label.text, label.score))
        }
        exit(0)
    }

    /// Dev-only: run the namer on the demo image, print the result, and exit.
    private func nameDemoAndExit() {
        SnapshotNamer.contextualName(for: DemoContent.makeBaseImage()) { name in
            print("NAME=\(name)")
            exit(0)
        }
    }

    /// Dev-only headless check: render the sample markup to /tmp and exit, so the
    /// renderer can be inspected without launching the full UI.
    private func renderDemoAndExit() {
        let canvas = CanvasView(document: DemoContent.makeDocument())
        if let png = canvas.flatten()?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "/tmp/clipandnote-demo.png"))
            NSLog("clipandnote demo: wrote /tmp/clipandnote-demo.png")
        }
        exit(0)
    }

    /// Dev-only: open an editor seeded with the given demo document.
    private func openDemo(_ document: MarkupDocument) {
        let editor = EditorWindowController(document: document)
        editors.append(editor)
        editor.show()
    }

    /// Minimal main menu so standard editing shortcuts (paste-as-object, copy,
    /// undo/redo) dispatch through the responder chain into the active canvas.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About clipandnote", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Preferences…",
                                   action: #selector(showPreferences(_:)), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit clipandnote",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File — open/save .can documents.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        // save: / saveAs: travel the responder chain to the key editor window.
        let saveItem = NSMenuItem(title: "Save…", action: #selector(EditorWindowController.save(_:)), keyEquivalent: "s")
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: "Save As…", action: #selector(EditorWindowController.saveAs(_:)), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAsItem)

        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(NSMenuItem(title: "PNG…", action: #selector(EditorWindowController.exportPNG(_:)), keyEquivalent: ""))
        exportMenu.addItem(NSMenuItem(title: "PDF…", action: #selector(EditorWindowController.exportPDF(_:)), keyEquivalent: ""))
        exportMenu.addItem(NSMenuItem(title: "SVG…", action: #selector(EditorWindowController.exportSVG(_:)), keyEquivalent: ""))
        exportItem.submenu = exportMenu
        fileMenu.addItem(exportItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)),
                                    keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

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

    @objc private func showPreferences(_ sender: Any?) { openPreferences() }

    private func openPreferences() {
        if prefsWindow == nil {
            let w = PreferencesWindowController()
            w.onChange = { [weak self] in
                self?.hotkeys.reload()
                self?.statusController.rebuild()
            }
            prefsWindow = w
        }
        prefsWindow?.show()
    }

    // MARK: - Documents

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.canDocument]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.openFile(url)
        }
    }

    /// Open a `.can` file into a new editor window (also the Finder double-click path).
    func openFile(_ url: URL) {
        // Focus an already-open window for this file rather than duplicating it.
        if let existing = editors.first(where: { $0.fileURL == url }) { existing.show(); return }
        do {
            let document = try CanFile.read(url)
            let editor = EditorWindowController(document: document)
            editor.setFileURL(url)
            editors.append(editor)
            editor.show()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openFile)
    }

    private func runCapture(_ kind: CaptureKind) {
        capture.capture(kind) { [weak self] image in
            guard let self, let image else { return }   // nil = user cancelled
            let editor = EditorWindowController(image: image)
            let stamp = SnapshotNamer.timestamp(Date())
            editor.setSnapshotTitle("\(stamp) · …")
            // Autosave to the library immediately (clipandcue captures everything).
            let id = MarkupLibrary.shared.add(editor.currentDocument, name: "\(stamp) · …", at: Date())
            editor.bindToLibrary(id)
            self.editors.append(editor)
            editor.show()
            // On-device OCR fills in a contextual name once it's ready.
            SnapshotNamer.contextualName(for: image) { name in
                editor.setSnapshotTitle("\(stamp) · \(name)")
            }
        }
    }

    // MARK: - Recents (the menu-bar cue)

    private func refreshRecents() {
        let items = MarkupLibrary.shared.recent(10).map {
            (title: $0.name, thumbnail: MarkupLibrary.shared.thumbnail($0.id))
        }
        statusController.updateRecents(items)
    }

    /// Click a recent markup → copy + open.
    private func pickRecent(_ index: Int) {
        let recents = MarkupLibrary.shared.recent(10)
        guard index < recents.count else { return }
        activateEntry(recents[index].id)
    }

    /// Copy a markup's flattened PNG to the clipboard (stamped so it doesn't flood
    /// clipandcue's queue) and open the .can for editing.
    private func activateEntry(_ id: UUID) {
        if let png = MarkupLibrary.shared.flatPNG(id) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(png, forType: .png)
            pb.setData(Data(), forType: .clipandnoteMarkup)
        }
        openLibraryEntry(id)
    }

    @objc private func openGallery(_ sender: Any?) {
        if galleryWindow == nil {
            let g = GalleryWindowController()
            g.onOpen = { [weak self] id in self?.activateEntry(id) }
            galleryWindow = g
        }
        galleryWindow?.show()
    }

    /// Open a library entry into an editor bound to it (so edits keep autosaving).
    private func openLibraryEntry(_ id: UUID) {
        if let existing = editors.first(where: { $0.libraryID == id }) { existing.show(); return }
        guard let doc = MarkupLibrary.shared.document(id) else { return }
        let editor = EditorWindowController(document: doc)
        if let name = MarkupLibrary.shared.entries.first(where: { $0.id == id })?.name {
            editor.setSnapshotTitle(name)
        }
        editor.bindToLibrary(id)
        editors.append(editor)
        editor.show()
    }

    /// Keep the app alive when the last editor window closes — it lives in the
    /// menu bar, like Skitch's capture-ready state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
