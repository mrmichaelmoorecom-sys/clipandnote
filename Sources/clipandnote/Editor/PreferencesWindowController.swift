import AppKit

/// Preferences: customize the global capture shortcuts.
final class PreferencesWindowController: NSWindowController {
    /// Fired when any shortcut changes, so hotkeys + the menu can refresh.
    var onChange: (() -> Void)?

    private var recorders: [ShortcutRecorderView] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        build()
    }

    private func build() {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 10
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Capture Shortcuts")
        header.font = .boldSystemFont(ofSize: 13)
        rows.addArrangedSubview(header)

        for (i, command) in CaptureCommand.allCases.enumerated() {
            let label = NSTextField(labelWithString: command.title)
            label.font = .systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 210).isActive = true

            let recorder = ShortcutRecorderView(shortcut: AppSettings.shared.shortcut(for: command))
            recorder.onChange = { [weak self] sc in
                AppSettings.shared.setShortcut(sc, for: command)
                self?.onChange?()
            }
            recorders.append(recorder)

            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
            clear.bezelStyle = .rounded
            clear.controlSize = .small
            clear.tag = i

            let row = NSStackView(views: [label, recorder, clear])
            row.orientation = .horizontal
            row.spacing = 10
            rows.addArrangedSubview(row)
        }

        let container = NSView()
        container.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        window?.contentView = container
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        let command = CaptureCommand.allCases[sender.tag]
        AppSettings.shared.setShortcut(.none, for: command)
        recorders[sender.tag].shortcut = .none
        onChange?()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
