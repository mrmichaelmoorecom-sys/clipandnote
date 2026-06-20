import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: a virtual key code plus modifier flags, with a captured
/// display character. Codable so it persists in preferences.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt          // NSEvent.ModifierFlags rawValue (device-independent)
    var key: String              // display char captured at record time, e.g. "4", "A"

    static let noneCode: UInt16 = 0xFFFF
    static let none = Shortcut(keyCode: noneCode, modifiers: 0, key: "")
    var isNone: Bool { keyCode == Self.noneCode }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// e.g. "⌘⌥4".
    var display: String {
        guard !isNone else { return "—" }
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    /// Modifiers in Carbon's representation, for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// The lowercased key equivalent string for display in an NSMenuItem.
    var menuKeyEquivalent: String { isNone ? "" : key.lowercased() }
}
