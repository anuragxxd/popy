import Carbon.HIToolbox

/// Registers a global keyboard shortcut (Cmd+Shift+V) so the user can
/// summon Popy from anywhere without reaching for the mouse.
///
/// Uses Carbon's RegisterEventHotKey which works without Accessibility
/// permissions (unlike CGEvent-based approaches).
final class HotkeyManager {

    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Called when the global hotkey is pressed.
    var onHotkey: (() -> Void)?

    private init() {}

    // MARK: - Register

    /// Register Cmd+Shift+V as a global hotkey.
    func register() {
        // Install a Carbon event handler for hotkey events
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(self).toOpaque()
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotkey?() }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )

        if handlerStatus != noErr {
            print("Popy [Hotkey] failed to install event handler: \(handlerStatus)")
            return
        }

        // "popy" as a 4-byte signature: 0x706F7079
        let hotKeyID = EventHotKeyID(signature: OSType(0x706F7079), id: 1)

        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            print("Popy [Hotkey] failed to register Cmd+Shift+V (status \(registerStatus)). Another app may own this shortcut.")
        }
    }

    // MARK: - Unregister

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
