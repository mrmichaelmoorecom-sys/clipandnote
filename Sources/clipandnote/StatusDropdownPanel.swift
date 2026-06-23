import AppKit
import SwiftUI

/// One recent-markup row's data shown in the menu-bar list.
struct RecentRowItem {
    let title: String
    let subtitle: String?      // unused since the user removed the second line
    let thumbnail: NSImage?
}

/// One capture-command row (Crosshair Snapshot etc.) with the hotkey on the right.
struct CaptureCommandItem: Identifiable {
    let id = UUID()
    let title: String
    let kind: CaptureKind
    let equiv: String
}

/// Backing model the menu-bar dropdown observes. Carries the same callbacks
/// and `setCaptureCommands` / `setRecents` surface the old AppKit
/// StatusDropdownContent exposed, so `StatusItemController` doesn't need to
/// change — `panel.content` is still the wiring hub.
final class StatusDropdownModel: ObservableObject {
    @Published var captureCommands: [CaptureCommandItem] = []
    @Published var recents: [RecentRowItem] = []
    @Published var checked: Set<Int> = []

    var onCapture: ((CaptureKind) -> Void)?
    var onPickRecent: ((Int) -> Void)?
    var onOpenGallery: (() -> Void)?
    var onPreferences: (() -> Void)?
    /// Export Selected (indices into the current recents list). Empty array =
    /// "export all" (the button title flips when nothing's checked).
    var onExport: (([Int]) -> Void)?
    /// Quit the app.
    var onQuit: (() -> Void)?
    /// Close the panel (Esc, outside-click, after a row pick).
    var onClose: (() -> Void)?

    func setCaptureCommands(_ commands: [(title: String, kind: CaptureKind, equiv: String)]) {
        captureCommands = commands.map {
            CaptureCommandItem(title: $0.title, kind: $0.kind, equiv: $0.equiv)
        }
    }

    func setRecents(_ items: [RecentRowItem]) {
        recents = items
        checked = []
    }
}

/// Floating dropdown for the menu-bar status item — clipandnote's equivalent
/// of clipandcue's clipboard panel. Hosts a SwiftUI content view inside an
/// NSHostingController so NSPopover's native vibrancy material composites
/// edge-to-edge (body + arrow tail) exactly like clipandcue does. The earlier
/// pure-AppKit content disturbed that compositing pipeline no matter how
/// transparent we made it.
final class StatusDropdownPanel: NSObject, NSPopoverDelegate {
    let content = StatusDropdownModel()
    private let popover = NSPopover()
    private var hostingController: NSHostingController<StatusDropdownContentView>!

    override init() {
        super.init()
        // Match clipandcue's setup verbatim: NSHostingController +
        // sizingOptions, nothing else. In particular DON'T touch
        // `view.wantsLayer` — an NSHostingView needs to stay layer-backed to
        // composite SwiftUI's vibrancy correctly. Forcing it off (a stale
        // tip meant for a plain NSView) made the dropdown render flat/opaque
        // instead of the translucent frosted-glass material clipandcue shows.
        hostingController = NSHostingController(rootView: StatusDropdownContentView(model: content))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // No appearance override — see popoverDidShow for the material fix.
    }

    /// clipandnote is a `.regular` app (it needs Dock + editor windows), so
    /// when its menu-bar NSPopover shows, the app is frontmost and the popover
    /// window becomes key — which makes its vibrancy render *emphasized*
    /// (lighter, blurrier). clipandcue is an `.accessory` agent, so its popover
    /// stays passive and gets the darker system-menu material. To match
    /// clipandcue (and the system Apple menu / Claude menu, which all share the
    /// same look) we force the popover's backing NSVisualEffectView to the
    /// `.menu` material, non-emphasized, once it's on screen.
    func popoverDidShow(_ notification: Notification) {
        guard let win = popover.contentViewController?.view.window,
              let root = win.contentView else { return }
        applyMenuMaterial(to: root)
    }

    private func applyMenuMaterial(to view: NSView) {
        if let ve = view as? NSVisualEffectView {
            ve.isEmphasized = false
        }
        for sub in view.subviews { applyMenuMaterial(to: sub) }
    }

    var isShown: Bool { popover.isShown }

    /// Show below the status item button — `.minY` makes the tail point up at
    /// the icon, matching clipandcue.
    func show(relativeTo button: NSView) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }
}

// MARK: - SwiftUI content

/// The dropdown contents — bare VStack with full-width Dividers and a
/// ScrollView for the recents list, matching clipandcue's structure exactly.
/// No `.background(...)` anywhere at the root so NSPopover's vibrancy
/// material shows through edge-to-edge.
struct StatusDropdownContentView: View {
    @ObservedObject var model: StatusDropdownModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            captureRows
            Divider()
            recentsHeader
            recentsScroll
            Divider()
            footer
        }
        // Width-only frame, intrinsic height — exactly like clipandcue's
        // `.frame(width: 380)`.
        .frame(width: 320)
        // .hudWindow material + a dark tint that the user dialled in for Dark
        // Mode. The tint only applies in Dark Mode — a 45%-black overlay in
        // Light Mode would muddy the light material into grey, so Light Mode
        // gets the material untinted.
        .background(
            MenuMaterialBackground()
                .overlay(colorScheme == .dark ? Color.black.opacity(0.45) : Color.clear)
        )
    }

    private var header: some View {
        HStack {
            Text("clipandnote")
                .font(.system(size: 13, weight: .semibold))
                // .primary adapts to the appearance — white on the dark menu,
                // black in Light Mode — so the title stays legible in both.
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var captureRows: some View {
        VStack(spacing: 0) {
            ForEach(model.captureCommands) { cmd in
                CaptureCommandRowView(
                    title: cmd.title,
                    equiv: cmd.equiv,
                    onClick: {
                        model.onCapture?(cmd.kind)
                        model.onClose?()
                    }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var recentsHeader: some View {
        HStack {
            Text("Recent Markups")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var recentsScroll: some View {
        Group {
            if model.recents.isEmpty {
                Text("No markups yet")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.recents.indices, id: \.self) { idx in
                            RecentRowView(
                                item: model.recents[idx],
                                isChecked: model.checked.contains(idx),
                                onTap: {
                                    model.onPickRecent?(idx)
                                    model.onClose?()
                                },
                                onToggle: { on in
                                    if on { model.checked.insert(idx) }
                                    else { model.checked.remove(idx) }
                                }
                            )
                        }
                    }
                }
                // maxHeight (not fixed height) so the list sizes to content up
                // to a cap, matching clipandcue's `.frame(maxHeight: 368)`.
                .frame(maxHeight: 300)
            }
        }
    }

    private var footer: some View {
        // All buttons use `.buttonStyle(.plain)` like clipandcue's footer.
        // The default Button style renders a bordered/glass capsule (lighter,
        // blurrier on macOS 26 Liquid Glass) behind each control, which made
        // clipandnote's dropdown read lighter than clipandcue's. Plain style
        // is just the label, so the popover vibrancy shows through unchanged.
        HStack(spacing: 12) {
            Button {
                model.onOpenGallery?()
                model.onClose?()
            } label: {
                Label("Library", systemImage: "books.vertical")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.onExport?(Array(model.checked).sorted())
                model.onClose?()
            } label: {
                Label(model.checked.isEmpty ? "Export" : "Export \(model.checked.count)",
                      systemImage: "square.and.arrow.up")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                model.onPreferences?()
                model.onClose?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Preferences")

            Button {
                model.onQuit?()
            } label: {
                Image(systemName: "power")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit clipandnote")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Row views

private struct CaptureCommandRowView: View {
    let title: String
    let equiv: String
    let onClick: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(equiv).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onClick() }
    }
}

private struct RecentRowView: View {
    let item: RecentRowItem
    let isChecked: Bool
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { isChecked },
                set: { onToggle($0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            thumbnail

            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered ? Color.accentColor.opacity(0.12) : Color.clear)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = item.thumbnail {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 34, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                )
        }
    }
}

/// SwiftUI bridge for an NSVisualEffectView rendering the system `.menu`
/// material, non-emphasized, sampling behind the window — the same dark
/// vibrant look macOS uses for the Apple menu, app menus, and the clipandcue
/// dropdown. Used as the dropdown's background since clipandnote (a `.regular`
/// app) can't get that material from NSPopover's own emphasized chrome.
private struct MenuMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        // `.hudWindow`: darker and crisper than `.popover` (less blur), and
        // saturated so the menu-bar / wallpaper colour reflects through the
        // top edge — the blue-tinted look clipandcue and the system menus
        // have. `.popover` was a touch light + too blurry; `.menu` was too
        // dark + blurry. behindWindow blending samples the desktop behind it.
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = false
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = .hudWindow
        v.isEmphasized = false
    }
}
