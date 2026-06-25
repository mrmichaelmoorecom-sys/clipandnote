import AppKit
import UniformTypeIdentifiers
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capture = CaptureEngine()
    private let hotkeys = HotkeyManager()
    private var statusController: StatusItemController!
    private var prefsWindow: PreferencesWindowController?
    private var galleryWindow: GalleryWindowController?
    /// Strong references so editor windows aren't deallocated while open.
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show tooltips faster than the macOS default (~1.5 s) — feels closer to
        // a labelled toolbar. NSInitialToolTipDelay still takes effect when
        // registered before AppKit reads it (i.e. during launch).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0.35])

        // Appearance follows the system automatically (NSApp.appearance left nil).
        buildMainMenu()
        let sc = StatusItemController()
        sc.onCapture = { [weak self] kind in self?.runCapture(kind) }
        sc.onPickRecent = { [weak self] idx in self?.pickRecent(idx) }
        sc.onReorderRecent = { from, to in MarkupLibrary.shared.moveRecent(from: from, to: to) }
        sc.onOpenGallery = { [weak self] in self?.openGallery(nil) }
        sc.onOpenFile = { [weak self] in self?.openDocument(nil) }
        sc.onNewWindow = { [weak self] in self?.showHome() }
        sc.onExportSelected = { [weak self] indices in self?.exportRecents(at: indices) }
        sc.onDeleteSelected = { [weak self] indices in self?.deleteRecents(at: indices) }
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
        case "exportall": exportAllTestAndExit()                 // headless: multi-page PDF
        default:       showHome()                                // normal launch → home window
        }
    }

    /// Dev-only: build a multi-page PDF from a couple of docs and count its pages.
    private func exportAllTestAndExit() {
        let docs = [DemoContent.makeDocument(), DemoContent.makeSmallDocument(), DemoContent.makeDocument()]
        if let pdf = MarkupExporter.multiPagePDF(docs) {
            let url = URL(fileURLWithPath: "/tmp/clipandnote-all.pdf")
            try? pdf.write(to: url)
            let pages = CGDataProvider(data: pdf as CFData).flatMap { CGPDFDocument($0)?.numberOfPages } ?? 0
            print("EXPORTALL docs=\(docs.count) pdfPages=\(pages) bytes=\(pdf.count)")
        }
        exit(0)
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
        registerEditor(editor)
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
        let newItem = NSMenuItem(title: "New Clip and Note",
                                 action: #selector(newClipAndNote(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        fileMenu.addItem(.separator())
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

        let exportAllItem = NSMenuItem(title: "Export All Markups…",
                                       action: #selector(exportAllMarkups(_:)), keyEquivalent: "")
        exportAllItem.target = self
        fileMenu.addItem(exportAllItem)

        fileMenu.addItem(.separator())
        // Revert travels the responder chain to the key editor window — same
        // pattern as Save / Save As. Disabled automatically when no editor
        // implements revertToOriginal:.
        let revertItem = NSMenuItem(title: "Revert clipandnote",
                                    action: #selector(EditorWindowController.revertToOriginal(_:)),
                                    keyEquivalent: "")
        fileMenu.addItem(revertItem)

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
        add("Duplicate", "duplicate:", "d")
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
        // From the menu-bar dropdown the app may not be active, which leaves the
        // open panel non-interactive — activate first, then run it modally.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.canDocument, .image, .pdf]   // .can, image, or PDF
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    /// Open a `.can` document — or import any image as a new markup — into a new
    /// editor window (also the Finder double-click path).
    func openFile(_ url: URL) {
        // Focus an already-open window for this file rather than duplicating it.
        if let existing = editors.first(where: { $0.fileURL == url }) { existing.show(); return }
        if url.pathExtension.lowercased() == "pdf" {
            if openPDF(url) { return }
            // fall through to the generic error if the PDF couldn't be read
        }
        if url.pathExtension.lowercased() == CanFile.ext {
            do {
                let pages = try CanFile.readPages(url)   // ≥1 page for any valid file
                let editor = pages.count > 1
                    ? EditorWindowController(pages: pages)
                    : EditorWindowController(document: pages[0])
                editor.setFileURL(url)
                registerEditor(editor)
                editor.show()
            } catch {
                NSAlert(error: error).runModal()
            }
        } else if let image = NSImage(contentsOf: url) {
            let editor = EditorWindowController(image: image)
            registerEditor(editor)
            editor.show()
            finishCapture(image, in: editor, replacingBlank: false)
        } else {
            let a = NSAlert()
            a.messageText = "Couldn’t open “\(url.lastPathComponent)”."
            a.informativeText = "It isn’t a clipandnote document or a supported image."
            a.runModal()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openFile)
    }

    /// Open a (possibly multi-page) PDF: render each page to a crisp image and
    /// hand them to one multi-page editor window. Export-to-PDF writes them all
    /// back as a single PDF. Returns false if the file isn't a readable PDF.
    @discardableResult
    func openPDF(_ url: URL) -> Bool {
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { return false }
        let scale: CGFloat = 2
        var docs: [MarkupDocument] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
            guard w > 0, h > 0, let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = box.size   // point size + 2× pixel rep = retina-crisp; the
            NSGraphicsContext.saveGraphicsState()              // context already maps points→pixels, so
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!  // we must NOT scale again here.
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            cg.translateBy(x: -box.minX, y: -box.minY)
            NSColor.white.setFill()
            NSRect(origin: box.origin, size: box.size).fill()
            page.draw(with: .mediaBox, to: cg)
            NSGraphicsContext.restoreGraphicsState()
            let img = NSImage(size: box.size)
            img.addRepresentation(rep)
            docs.append(MarkupDocument(baseImage: img, objects: [], canvasSize: box.size))
        }
        guard !docs.isEmpty else { return false }
        let editor = EditorWindowController(pages: docs)
        let title = "\(url.deletingPathExtension().lastPathComponent) (\(docs.count) page\(docs.count == 1 ? "" : "s"))"
        editor.setSnapshotTitle(title)
        // Autosave to the library like any capture — opening a PDF now persists
        // all pages, so closing without exporting no longer loses the markup.
        let id = MarkupLibrary.shared.add(pages: docs, name: title, at: Date())
        editor.bindToLibrary(id)
        registerEditor(editor)
        editor.show()
        return true
    }

    private func runCapture(_ kind: CaptureKind) {
        capture.capture(kind) { [weak self] image in
            guard let self, let image else { return }   // nil = user cancelled
            let editor = EditorWindowController(image: image)
            self.registerEditor(editor)
            editor.show()
            self.finishCapture(image, in: editor, replacingBlank: false)
        }
    }

    /// Toolbar crosshair grab: hide the editor so it's not in the shot, capture
    /// a region, then drop it onto the canvas — as the base image if the canvas
    /// is blank, otherwise as a movable image object.
    private func grabCrosshairInto(_ editor: EditorWindowController) {
        let wasBlank = editor.isBlank
        editor.window?.orderOut(nil)
        capture.capture(.crosshair) { [weak self] image in
            editor.window?.makeKeyAndOrderFront(nil)
            guard let image else { return }   // cancelled
            if wasBlank {
                self?.finishCapture(image, in: editor, replacingBlank: true)
            } else {
                editor.addCanvasImage(image)
            }
        }
    }

    /// Register a fresh capture into the library and start naming it.
    private func finishCapture(_ image: NSImage, in editor: EditorWindowController, replacingBlank: Bool) {
        if replacingBlank { editor.setBaseImage(image) }
        let stamp = SnapshotNamer.timestamp(Date())
        editor.setSnapshotTitle("\(stamp) · …")
        let id = MarkupLibrary.shared.add(editor.currentDocument, name: "\(stamp) · …", at: Date())
        editor.bindToLibrary(id)
        SnapshotNamer.contextualName(for: image) { name in
            editor.setSnapshotTitle("\(stamp) · \(name)")
        }
    }

    // MARK: - Home (blank) window

    /// File ▸ New Clip and Note — opens a fresh default (home) window.
    @objc private func newClipAndNote(_ sender: Any?) { showHome() }

    /// The standalone window shown on launch: toolbar + open/capture/drop area.
    private func showHome() {
        let editor = EditorWindowController()
        editor.onRequestOpen = { [weak self, weak editor] in
            guard let editor else { return }; self?.openInto(editor)
        }
        editor.onRequestCapture = { [weak self, weak editor] in
            guard let editor else { return }; self?.captureInto(editor)
        }
        editor.onCaptureImage = { [weak self, weak editor] image in
            guard let editor else { return }; self?.finishCapture(image, in: editor, replacingBlank: true)
        }
        editor.onOpenCanURL = { [weak editor] url in
            guard let editor, let doc = try? CanFile.read(url) else { return }
            editor.loadCan(doc, url: url)
        }
        registerEditor(editor)
        editor.show()
    }

    /// Common per-editor wiring + tracking. Every editor goes through here so
    /// the toolbar crosshair grab works regardless of how the editor was made.
    private func registerEditor(_ editor: EditorWindowController) {
        editor.onCrosshairGrab = { [weak self] ed in self?.grabCrosshairInto(ed) }
        editors.append(editor)
    }

    private func openInto(_ editor: EditorWindowController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.canDocument, .image, .pdf]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            if url.pathExtension.lowercased() == "pdf" {
                self?.openPDF(url)   // multi-page PDFs open in their own window
            } else if url.pathExtension.lowercased() == CanFile.ext {
                if let doc = try? CanFile.read(url) { editor.loadCan(doc, url: url) }
            } else if let image = NSImage(contentsOf: url) {
                self?.finishCapture(image, in: editor, replacingBlank: true)
            }
        }
    }

    private func captureInto(_ editor: EditorWindowController) {
        capture.capture(.crosshair) { [weak self] image in
            guard let self, let image else { return }
            self.finishCapture(image, in: editor, replacingBlank: true)
        }
    }

    /// Reopen the home window when the dock icon is clicked with no windows open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHome() }
        return true
    }

    // MARK: - Recents (the menu-bar cue)

    private func refreshRecents() {
        let items = MarkupLibrary.shared.recent(60).map { entry -> RecentRowItem in
            // Subtitle reads like clipandcue's "Image · 826×98": kind label
            // + canvas dimensions, separated by a thin dot.
            let dims = "\(entry.width) × \(entry.height)"
            return RecentRowItem(title: entry.name,
                                 subtitle: "Markup · \(dims)",
                                 thumbnail: MarkupLibrary.shared.thumbnail(entry.id))
        }
        statusController.updateRecents(items)
    }

    /// Click a recent markup → copy + open.
    private func pickRecent(_ index: Int) {
        let recents = MarkupLibrary.shared.recent(60)
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

    // MARK: - Export all markups

    /// Status-panel "Export" button.
    /// - Empty `indices` (button title is just "Export"): open the
    ///   MergeSelectionWindowController thumbnail picker — same workflow as the
    ///   old File ▸ Export All menu — so the user can re-confirm the set
    ///   visually before exporting.
    /// - Non-empty `indices` (button title "Export N"): they've already chosen
    ///   in the menu; go straight to the PDF / Folder format dialog scoped to
    ///   those picks.
    private func exportRecents(at indices: [Int]) {
        let recents = MarkupLibrary.shared.recent(60)

        if indices.isEmpty {
            exportAllMarkups(nil)   // shares the thumbnail-picker path
            return
        }

        let chosen = indices.compactMap { i in (i >= 0 && i < recents.count) ? recents[i] : nil }
        guard !chosen.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Export \(chosen.count) Markup\(chosen.count == 1 ? "" : "s")"
        alert.informativeText = "Combine into one multi-page PDF, or write a folder of individual files."
        alert.addButton(withTitle: "Multi-page PDF…")
        alert.addButton(withTitle: "Folder of Files…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  exportAllPDF(chosen)
        case .alertSecondButtonReturn: exportAllFolder(chosen)
        default: break
        }
    }

    /// Delete button in the dropdown. Mirrors export: checked markups are
    /// deleted (after a confirm); with nothing checked, open the library so the
    /// user can pick what to remove there.
    private func deleteRecents(at indices: [Int]) {
        let recents = MarkupLibrary.shared.recent(60)
        let chosen = indices.compactMap { i in (i >= 0 && i < recents.count) ? recents[i] : nil }
        guard !chosen.isEmpty else { openGallery(nil); return }

        let alert = NSAlert()
        alert.messageText = "Delete \(chosen.count) Markup\(chosen.count == 1 ? "" : "s")?"
        alert.informativeText = "This permanently removes \(chosen.count == 1 ? "it" : "them") from your library. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        chosen.forEach { MarkupLibrary.shared.delete($0.id) }   // library onChange refreshes the list
    }

    @objc private func exportAllMarkups(_ sender: Any?) {
        let entries = MarkupLibrary.shared.recent(.max)
        guard !entries.isEmpty else {
            let a = NSAlert(); a.messageText = "No markups to export yet."; a.runModal(); return
        }
        let alert = NSAlert()
        alert.messageText = "Export \(entries.count) Markups"
        alert.informativeText = "Combine into one multi-page PDF, or write a folder of individual files."
        alert.addButton(withTitle: "Multi-page PDF…")
        alert.addButton(withTitle: "Folder of Files…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  chooseAndMergePDF()
        case .alertSecondButtonReturn: exportAllFolder(entries)
        default: break
        }
    }

    private var mergeSelection: MergeSelectionWindowController?

    /// Pop the thumbnail picker and merge the ticked markups; the picker
    /// controls sort order (= page order) and whether to add page numbers.
    private func chooseAndMergePDF() {
        // Open in the same manual order shown in the menu (newest on top, plus
        // any drag-reorder the user applied); the picker can reorder further.
        let ordered = MarkupLibrary.shared.recent(.max)
        let wc = MergeSelectionWindowController(entries: ordered) { [weak self] selected, paginate in
            guard !selected.isEmpty else { return }
            self?.exportAllPDF(selected, paginate: paginate)
            self?.mergeSelection = nil
        }
        mergeSelection = wc
        wc.show()
    }

    private func exportAllPDF(_ entries: [MarkupLibrary.Entry], paginate: Bool = false) {
        let docs = entries.compactMap { MarkupLibrary.shared.document($0.id) }
        guard let pdf = MarkupExporter.multiPagePDF(docs, paginate: paginate) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "clipandnote markups.pdf"
        if let dir = AppSettings.shared.saveDirectory { panel.directoryURL = dir }
        panel.begin { resp in
            if resp == .OK, let url = panel.url { try? pdf.write(to: url) }
        }
    }

    private func exportAllFolder(_ entries: [MarkupLibrary.Entry]) {
        let fmt = NSAlert()
        fmt.messageText = "File format"
        ["PNG", "PDF", "SVG", "Cancel"].forEach { fmt.addButton(withTitle: $0) }
        let ext: String
        switch fmt.runModal() {
        case .alertFirstButtonReturn:  ext = "png"
        case .alertSecondButtonReturn: ext = "pdf"
        case .alertThirdButtonReturn:  ext = "svg"
        default: return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export Here"
        if let dir = AppSettings.shared.saveDirectory { panel.directoryURL = dir }
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            for (i, entry) in entries.enumerated() {
                guard let doc = MarkupLibrary.shared.document(entry.id) else { continue }
                let data: Data?
                switch ext {
                case "pdf": data = MarkupExporter.pdf(doc)
                case "svg": data = SVGExporter.svg(doc).data(using: .utf8)
                default:    data = MarkupExporter.png(doc)
                }
                guard let data else { continue }
                let safe = entry.name.replacingOccurrences(of: "/", with: "-")
                let name = String(format: "%03d %@.%@", i + 1, safe, ext)
                try? data.write(to: dir.appendingPathComponent(name))
            }
        }
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
        let entry = MarkupLibrary.shared.entries.first(where: { $0.id == id })
        let editor: EditorWindowController
        if (entry?.pageCount ?? 1) > 1, let pages = MarkupLibrary.shared.pages(id), pages.count > 1 {
            editor = EditorWindowController(pages: pages)   // reopen the full multi-page window
        } else {
            guard let doc = MarkupLibrary.shared.document(id) else { return }
            editor = EditorWindowController(document: doc)
        }
        if let name = entry?.name { editor.setSnapshotTitle(name) }
        editor.bindToLibrary(id)
        registerEditor(editor)
        editor.show()
    }

    /// Keep the app alive when the last editor window closes — it lives in the
    /// menu bar, like Skitch's capture-ready state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
