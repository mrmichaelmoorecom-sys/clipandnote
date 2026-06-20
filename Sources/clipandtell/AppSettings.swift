import Foundation

/// Lightweight user preferences, backed by UserDefaults. Mirrors the simple
/// settings style used in clipandcue.
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let timedDelay = "timedDelaySeconds"
        static let historyLimit = "localHistoryLimit"
        static let copyAfterCapture = "copyAfterCapture"
        static let syncEnabled = "syncEnabled"
        static let appearance = "appearance"
    }

    private init() {
        defaults.register(defaults: [
            Key.timedDelay: 5,
            Key.historyLimit: 100,     // how many markups to keep locally (gallery)
            Key.copyAfterCapture: true,
            Key.syncEnabled: false,    // CloudKit off until set up
            Key.appearance: "system",
        ])
    }

    /// "system", "light", or "dark".
    var appearance: String {
        get { defaults.string(forKey: Key.appearance) ?? "system" }
        set { defaults.set(newValue, forKey: Key.appearance) }
    }

    /// Delay (seconds) for the "Timed Crosshair Snapshot" command.
    var timedDelaySeconds: Int {
        get { defaults.integer(forKey: Key.timedDelay) }
        set { defaults.set(newValue, forKey: Key.timedDelay) }
    }

    /// How many past markups to retain in the local gallery (user-tunable).
    var localHistoryLimit: Int {
        get { defaults.integer(forKey: Key.historyLimit) }
        set { defaults.set(newValue, forKey: Key.historyLimit) }
    }

    /// Place the flattened result on the pasteboard after each capture/export.
    var copyAfterCapture: Bool {
        get { defaults.bool(forKey: Key.copyAfterCapture) }
        set { defaults.set(newValue, forKey: Key.copyAfterCapture) }
    }

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Key.syncEnabled) }
        set { defaults.set(newValue, forKey: Key.syncEnabled) }
    }
}
