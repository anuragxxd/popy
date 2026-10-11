import AppKit
import Carbon.HIToolbox

/// Detects a double-tap of the Fn (globe) key anywhere in the system.
///
/// Carbon's `RegisterEventHotKey` (used by `HotkeyManager`) cannot bind Fn —
/// Fn is not exposed as a Carbon hotkey modifier. So we watch raw
/// `.flagsChanged` events instead.
///
/// Two important caveats:
///
/// 1. `NSEvent` global monitors are **passive** — we observe the event but
///    cannot consume it, so the system's own Fn action (the emoji picker by
///    default) would still fire. `FnSystemActionOverride` therefore sets
///    "Press 🌐 key to" → **Do Nothing** while the listener runs, and puts the
///    user's choice back when it stops.
///
/// 2. Contrary to what you might expect, `.flagsChanged` monitoring does NOT
///    require Accessibility or Input Monitoring — modifier state is not
///    treated as sensitive keystroke content the way `.keyDown` is. Verified
///    on macOS 12 with an app holding neither `kTCCServiceAccessibility` nor
///    `kTCCServiceListenEvent`. So never gate this feature on
///    `AXIsProcessTrusted()`; use `isReceivingEvents` as the ground truth
///    instead. Accessibility is only needed to *post* events (pasting).
final class FnKeyListener {

    static let shared = FnKeyListener()

    /// Virtual keycode for the Fn / globe key.
    private static let fnKeyCode: UInt16 = UInt16(kVK_Function)

    /// Maximum gap between the two Fn presses to count as a double-tap.
    /// 300ms is tight for Fn (which has noticeable debounce on some
    /// keyboards); 400ms is comfortable without catching unrelated presses.
    private let doubleTapWindow: TimeInterval = 0.4

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var lastPressTime: TimeInterval = 0
    private var fnIsDown = false

    /// Set to true once we have actually observed an Fn event, which proves
    /// Accessibility permission is live.
    private(set) var isReceivingEvents = false

    /// Fired on the main queue when Fn is tapped twice in quick succession.
    var onDoubleTap: (() -> Void)?

    private init() {}

    // MARK: - Lifecycle

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }

        FnSystemActionOverride.apply()

        // Global: fires when any *other* app is frontmost. This is the normal case
        // for Popy, which is an LSUIElement (menu-bar-only) app.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
        }

        // Local: global monitors do not fire when our own process is frontmost
        // (e.g. while an NSAlert is up), so mirror it locally.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        fnIsDown = false
        lastPressTime = 0
        FnSystemActionOverride.restore()
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
        // Liveness is recorded for *any* modifier event, not just Fn. Shift and
        // Command fire constantly during normal typing, so this becomes true
        // within seconds — which makes it a far better signal that the monitor
        // is alive than waiting for a specific Fn press.
        isReceivingEvents = true

        // Gate on the keycode, NOT on the `.function` modifier flag alone.
        // Arrow keys, F-keys, Home/End/PageUp/PageDown all set `.function`
        // too — only the physical Fn key reports keyCode 63.
        guard event.keyCode == Self.fnKeyCode else { return }

        let isDown = event.modifierFlags.contains(.function)

        // `.flagsChanged` fires on both press and release. Only count presses,
        // and ignore any repeat while the key is physically held.
        guard isDown, !fnIsDown else {
            fnIsDown = isDown
            return
        }
        fnIsDown = true

        let now = event.timestamp
        let elapsed = now - lastPressTime

        if elapsed > 0, elapsed <= doubleTapWindow {
            // Reset so a third tap starts a fresh pair rather than
            // immediately re-triggering.
            lastPressTime = 0
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleTap?()
            }
        } else {
            lastPressTime = now
        }
    }
}

// MARK: - System Fn action

/// Suppresses the system's Fn (globe) action — the emoji picker by default —
/// while Popy is listening for Fn Fn.
///
/// This is the same preference System Settings → Keyboard → "Press 🌐 key to"
/// writes: `AppleFnUsageType` in `com.apple.HIToolbox`
/// (0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation).
/// Consuming the event ourselves is not an option: the picker is triggered
/// below the level a passive monitor can see, and an event tap would need
/// Input Monitoring permission that this feature otherwise avoids.
///
/// The user's original value is persisted before it is overridden, so it
/// survives a crash and is restored on the next clean stop.
enum FnSystemActionOverride {

    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    private static let doNothing = 0

    /// Popy's own record of the user's value. Absent: nothing overridden.
    /// -1: the key was unset (system default) before we touched it.
    private static let savedKey = "savedAppleFnUsageType"
    private static let unsetMarker = -1

    static func apply() {
        let current = readValue()
        guard current != doNothing else { return }

        // Only record the original once — after a crash the current value is
        // already ours, and overwriting would lose the user's real setting.
        if UserDefaults.standard.object(forKey: savedKey) == nil {
            UserDefaults.standard.set(current ?? unsetMarker, forKey: savedKey)
        }
        writeValue(doNothing)
    }

    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Int else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)

        // If the user changed the setting themselves while Popy ran, theirs wins.
        guard readValue() == doNothing else { return }
        writeValue(saved == unsetMarker ? nil : saved)
    }

    private static func readValue() -> Int? {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
    }

    private static func writeValue(_ value: Int?) {
        CFPreferencesSetValue(key, value.map { $0 as CFNumber }, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        activate()
    }

    /// Writing the preference alone only takes effect at next login.
    /// `activateSettings -u` is what System Settings uses to apply keyboard
    /// preferences to the running session.
    private static func activate() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-u"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            print("Popy [Fn] could not apply keyboard settings: \(error.localizedDescription)")
        }
    }
}
