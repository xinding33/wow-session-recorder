import Carbon.HIToolbox
import os

struct Hotkey: Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    static let bookmark = Hotkey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥B")
    static let clip = Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥C")
}

/// System-wide hotkeys that work while WoW has focus.
///
/// Uses Carbon's `RegisterEventHotKey`, which needs no Accessibility permission. The key press
/// is consumed, so WoW won't also see it.
@MainActor
final class HotkeyManager {
    private let log = Logger(subsystem: "SessionRecorder", category: "Hotkeys")
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    func register(_ hotkey: Hotkey, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x5752_4543), id: nextID) // 'WREC'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("Couldn't register \(hotkey.display, privacy: .public): \(status)")
            return
        }
        refs.append(ref)
        actions[nextID] = action
        nextID += 1
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { manager.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
