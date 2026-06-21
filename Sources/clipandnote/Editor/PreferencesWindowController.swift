import AppKit

/// Preferences: customize the global capture shortcuts.
final class PreferencesWindowController: NSWindowController {
    /// Fired when any shortcut changes, so hotkeys + the menu can refresh.
    var onChange: (() -> Void)?

    private var recorders: [ShortcutRecorderView] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
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

        let autosaveHeader = NSTextField(labelWithString: "Library")
        autosaveHeader.font = .boldSystemFont(ofSize: 13)
        rows.addArrangedSubview(autosaveHeader)
        rows.addArrangedSubview(autosaveRow())

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        rows.addArrangedSubview(spacer)

        let header = NSTextField(labelWithString: "Capture Shortcuts")
        header.font = .boldSystemFont(ofSize: 13)
        rows.addArrangedSubview(header)
        rows.addArrangedSubview(captureDelayRow())

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

    private var autosaveField: NSTextField!
    private var autosaveStepper: NSStepper!

    /// "Keep this many recent auto-saves" — drives the library's retention limit.
    private func autosaveRow() -> NSView {
        let label = NSTextField(labelWithString: "Keep this many recent auto-saves:")
        label.font = .systemFont(ofSize: 12)

        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        field.alignment = .right
        field.integerValue = AppSettings.shared.localHistoryLimit
        field.target = self
        field.action = #selector(autosaveFieldChanged(_:))
        self.autosaveField = field

        let stepper = NSStepper()
        stepper.minValue = 5
        stepper.maxValue = 5000
        stepper.increment = 5
        stepper.valueWraps = false
        stepper.integerValue = AppSettings.shared.localHistoryLimit
        stepper.target = self
        stepper.action = #selector(autosaveStepperChanged(_:))
        self.autosaveStepper = stepper

        let row = NSStackView(views: [label, field, stepper])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func setAutosaveLimit(_ value: Int) {
        let clamped = max(5, min(5000, value))
        AppSettings.shared.localHistoryLimit = clamped
        autosaveField.integerValue = clamped
        autosaveStepper.integerValue = clamped
        MarkupLibrary.shared.applyRetention()
    }

    @objc private func autosaveFieldChanged(_ sender: NSTextField) { setAutosaveLimit(sender.integerValue) }
    @objc private func autosaveStepperChanged(_ sender: NSStepper) { setAutosaveLimit(sender.integerValue) }

    private var delayField: NSTextField!
    private var delayStepper: NSStepper!

    /// "Timed / Menu snapshot countdown" — seconds before those captures fire.
    private func captureDelayRow() -> NSView {
        let label = NSTextField(labelWithString: "Timed / Menu countdown (seconds):")
        label.font = .systemFont(ofSize: 12)

        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        field.alignment = .right
        field.integerValue = AppSettings.shared.timedDelaySeconds
        field.target = self
        field.action = #selector(delayFieldChanged(_:))
        self.delayField = field

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 60
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = AppSettings.shared.timedDelaySeconds
        stepper.target = self
        stepper.action = #selector(delayStepperChanged(_:))
        self.delayStepper = stepper

        let row = NSStackView(views: [label, field, stepper])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func setCaptureDelay(_ value: Int) {
        let clamped = max(1, min(60, value))
        AppSettings.shared.timedDelaySeconds = clamped
        delayField.integerValue = clamped
        delayStepper.integerValue = clamped
    }

    @objc private func delayFieldChanged(_ sender: NSTextField) { setCaptureDelay(sender.integerValue) }
    @objc private func delayStepperChanged(_ sender: NSStepper) { setCaptureDelay(sender.integerValue) }

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
