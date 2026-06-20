import AppKit
import Carbon.HIToolbox

/// Registers the configured capture shortcuts as system-wide hotkeys (Carbon
/// RegisterEventHotKey — no special permission needed, unlike event taps) and
/// fires `onCapture` from any app. Call `reload()` after the shortcuts change.
final class HotkeyManager {
    var onCapture: ((CaptureKind) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var idToKind: [UInt32: CaptureKind] = [:]

    func reload() {
        unregisterHotKeys()
        installHandlerIfNeeded()

        var nextID: UInt32 = 1
        for command in CaptureCommand.allCases {
            let sc = AppSettings.shared.shortcut(for: command)
            guard !sc.isNone else { continue }
            let hotKeyID = EventHotKeyID(signature: OSType(0x434C5450), id: nextID)  // 'CLTP'
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(sc.keyCode), sc.carbonModifiers,
                                             hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                idToKind[nextID] = command.kind
            }
            nextID += 1
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let kind = me.idToKind[hkID.id] {
                DispatchQueue.main.async { me.onCapture?(kind) }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func unregisterHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        idToKind.removeAll()
    }

    deinit {
        unregisterHotKeys()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
