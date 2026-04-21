import Carbon.HIToolbox
import Foundation

/// System-wide hotkey registration via the Carbon HotKey API.
///
/// Unlike NSEvent.addGlobalMonitorForEvents, this consumes the keypress
/// (other apps won't receive it) and does not require Accessibility permission.
enum GlobalHotKey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handler: (() -> Void)?
    private static var eventHandlerRef: EventHandlerRef?

    /// Register a global hotkey. Returns true on success.
    ///
    /// - keyCode: a `kVK_*` virtual keycode from Carbon.HIToolbox.
    /// - modifiers: OR of Carbon modifier masks (cmdKey, optionKey, shiftKey, controlKey).
    @discardableResult
    static func register(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) -> Bool {
        unregister()
        handler = onFire

        // 'GVLP' as signature — a stable 4-char identifier for gavel's hotkey.
        let hotKeyID = EventHotKeyID(signature: 0x47564C50, id: 1)
        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard regStatus == noErr, let ref else {
            gavelLog("GlobalHotKey: RegisterEventHotKey failed status=\(regStatus) — another app may own this shortcut")
            return false
        }
        hotKeyRef = ref

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { GlobalHotKey.handler?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            gavelLog("GlobalHotKey: InstallEventHandler failed status=\(installStatus)")
            unregister()
            return false
        }
        return true
    }

    static func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let eh = eventHandlerRef {
            RemoveEventHandler(eh)
            eventHandlerRef = nil
        }
        handler = nil
    }
}
