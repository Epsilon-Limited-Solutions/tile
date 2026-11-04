import Carbon.HIToolbox
import TileCore

/// System-wide hotkeys through Carbon's RegisterEventHotKey, which needs no Input
/// Monitoring permission. Each distinct combo is registered once; which binding it
/// triggers is decided at press time (WindowCommands.press). Generalizes Momentum's
/// GlobalHotkeyManager from one hotkey to many.
@MainActor
final class HotkeyManager {
    /// Combos that couldn't be registered, and why.
    private(set) var unavailable: [(combo: KeyCombo, reason: String)] = []
    var registeredCount: Int { hotKeyRefs.count }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var combosByID: [UInt32: KeyCombo] = [:]
    private var handlerRef: EventHandlerRef?
    private let onPress: (KeyCombo) -> Void
    /// Bare Esc, held only while an arrangement runs so it can be cancelled.
    private var escapeRef: EventHotKeyRef?
    private var onEscape: (() -> Void)?
    private static let escapeID: UInt32 = 0xE5C
    private static let signature = OSType(0x5449_4C45) // "TILE"

    init(onPress: @escaping (KeyCombo) -> Void) {
        self.onPress = onPress
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // The application event target dispatches on the main thread.
            MainActor.assumeIsolated { manager.pressed(hotKeyID) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        if status != noErr { Log.app.error("installing the hotkey handler failed: \(status)") }
    }

    /// Replaces every registered hotkey with `combos`.
    func register(_ combos: [KeyCombo]) {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        combosByID = [:]
        unavailable = []
        for (index, combo) in combos.enumerated() {
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.carbonFlags, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                combosByID[id.id] = combo
            } else {
                let reason = switch Int(status) {
                case eventHotKeyExistsErr: "taken by another app"
                case eventHotKeyInvalidErr: "refused by macOS"
                default: "error \(status)"
                }
                unavailable.append((combo, reason))
                Log.app.error("hotkey \(combo.description, privacy: .public) unavailable: \(reason, privacy: .public)")
            }
        }
        Log.app.info("registered \(self.hotKeyRefs.count) hotkeys, \(self.unavailable.count) unavailable")
    }

    /// Takes Esc system-wide until `releaseEscape()`. Other apps don't see Esc meanwhile.
    func holdEscape(_ handler: @escaping () -> Void) {
        releaseEscape()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.escapeID)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.app.error("couldn't take Esc (\(status)); the arrangement can't be cancelled")
            return
        }
        escapeRef = ref
        onEscape = handler
    }

    func releaseEscape() {
        if let escapeRef { UnregisterEventHotKey(escapeRef) }
        escapeRef = nil
        onEscape = nil
    }

    private func pressed(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        if id.id == Self.escapeID {
            onEscape?()
            return
        }
        guard let combo = combosByID[id.id] else { return }
        onPress(combo)
    }
}
