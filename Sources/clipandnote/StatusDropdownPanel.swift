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
        hostingController = NSHostingController(rootView: StatusDropdownContentView(model: content))
        // Lets NSPopover read the SwiftUI view's .frame(...) as its size.
        hostingController.sizingOptions = [.preferredContentSize]
        // NSPopover's window is layer-backed and can implicitly promote
        // contentViewController.view too. A backing layer here introduces a
        // separate compositing surface that disturbs the popover's vibrancy
        // — same opt-out clipandcue uses.
        hostingController.view.wantsLayer = false
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // No appearance override. With the deployment target lowered to
        // macOS 13 (matching clipandcue), NSPopover follows the system
        // appearance and renders the dark vibrant material under Dark Mode
        // automatically — exactly like clipandcue. The macOS-14 deployment
        // target was the sole cause of the previously-light dropdown.
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

    /// Brand purple title tint — the lighter of the two tones in
    /// `img/mark_accent_v2.svg`.
    private let brandPurple = Color(red: 0xa2/255.0, green: 0x9a/255.0, blue: 0xb1/255.0)

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
        .frame(width: 320, height: 500)
    }

    private var header: some View {
        HStack {
            Text("clipandnote")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(brandPurple)
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
            }
        }
        .frame(height: 260)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.onOpenGallery?()
                model.onClose?()
            } label: {
                Label("Library", systemImage: "books.vertical")
            }
            .controlSize(.small)

            Spacer()

            Button(model.checked.isEmpty ? "Export" : "Export \(model.checked.count)") {
                model.onExport?(Array(model.checked).sorted())
                model.onClose?()
            }
            .controlSize(.small)

            Button {
                model.onPreferences?()
                model.onClose?()
            } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
            .help("Preferences")

            Button {
                model.onQuit?()
            } label: {
                Image(systemName: "power")
            }
            .controlSize(.small)
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
