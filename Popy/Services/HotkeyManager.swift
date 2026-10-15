import Carbon.HIToolbox

/// Registers global keyboard shortcuts: Cmd+Shift+V, so the user can summon
/// Popy from anywhere without reaching for the mouse, and Esc while
/// dictating, so a recording can be thrown away.
///
/// Uses Carbon's RegisterEventHotKey which works without Accessibility
/// permissions (unlike CGEvent-based approaches). A registered hotkey is
/// consumed: the frontmost app never sees it. That is exactly what Esc needs —
/// a cancel that also reached the app being dictated into would close its
/// dialog or abandon its edit.
final class HotkeyManager {

    static let shared = HotkeyManager()

    private enum HotkeyID: UInt32 {
        case showMenu = 1
        case cancelDictation = 2
    }

    /// "popy" as a 4-byte signature: 0x706F7079
    private static let signature = OSType(0x706F7079)

    private var hotKeyRef: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Called when Cmd+Shift+V is pressed.
    var onHotkey: (() -> Void)?

    /// Called when Esc is pressed while it is registered.
    var onEscape: (() -> Void)?

    private init() {}

    // MARK: - Register

    /// Register Cmd+Shift+V as a global hotkey.
    func register() {
        guard installHandlerIfNeeded() else { return }

        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: Self.signature, id: HotkeyID.showMenu.rawValue),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            print("Popy [Hotkey] failed to register Cmd+Shift+V (status \(registerStatus)). Another app may own this shortcut.")
        }
    }

    /// Take Esc for as long as a recording is running.
    ///
    /// It must be released the moment the recording ends: while registered,
    /// Esc is swallowed system-wide and no other app can use it.
    func setEscapeEnabled(_ enabled: Bool) {
        if !enabled {
            if let ref = escapeRef {
                UnregisterEventHotKey(ref)
                escapeRef = nil
            }
            return
        }

        guard escapeRef == nil, installHandlerIfNeeded() else { return }

        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: Self.signature, id: HotkeyID.cancelDictation.rawValue),
            GetApplicationEventTarget(),
            0,
            &escapeRef
        )

        if status != noErr {
            escapeRef = nil
            print("Popy [Hotkey] failed to register Esc (status \(status)).")
        }
    }

    /// One handler serves every hotkey and routes on the ID it was registered with.
    private func installHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(self).toOpaque()
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotkeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                switch HotkeyID(rawValue: hotKeyID.id) {
                case .showMenu:
                    DispatchQueue.main.async { manager.onHotkey?() }
                case .cancelDictation:
                    DispatchQueue.main.async { manager.onEscape?() }
                case nil:
                    return OSStatus(eventNotHandledErr)
                }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )

        if handlerStatus != noErr {
            print("Popy [Hotkey] failed to install event handler: \(handlerStatus)")
            eventHandlerRef = nil
            return false
        }
        return true
    }

    // MARK: - Unregister

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        setEscapeEnabled(false)
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
