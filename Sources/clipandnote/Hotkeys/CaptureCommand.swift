import AppKit
import Carbon.HIToolbox

/// The capturable commands, their menu titles, and their default shortcuts.
/// Defaults use ⌘⌥ (command-option) to avoid colliding with the macOS system
/// screenshot shortcuts (⌘⇧3 / ⌘⇧4 / ⌘⇧5).
enum CaptureCommand: String, CaseIterable {
    case crosshair, previousArea, fullscreen, window, menu

    var kind: CaptureKind {
        switch self {
        case .crosshair:    return .crosshair
        case .previousArea: return .previousArea
        case .fullscreen:   return .fullscreen
        case .window:       return .window
        case .menu:         return .menu
        }
    }

    var title: String {
        switch self {
        case .crosshair:    return "Crosshair Clip"
        case .previousArea: return "Previous Clip Area"
        case .fullscreen:   return "Fullscreen Clip"
        case .window:       return "Window Clip…"
        case .menu:         return "Menu Clip"
        }
    }

    var defaultShortcut: Shortcut {
        let cmdOpt = NSEvent.ModifierFlags([.command, .option]).rawValue
        func sc(_ code: Int, _ key: String) -> Shortcut {
            Shortcut(keyCode: UInt16(code), modifiers: cmdOpt, key: key)
        }
        switch self {
        case .crosshair:    return sc(kVK_ANSI_4, "4")
        case .fullscreen:   return sc(kVK_ANSI_3, "3")
        case .window:       return sc(kVK_ANSI_5, "5")
        case .previousArea: return sc(kVK_ANSI_6, "6")
        case .menu:         return .none      // unset by default
        }
    }
}
