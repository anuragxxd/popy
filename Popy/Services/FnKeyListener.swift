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
///    cannot consume it. The system's own Fn action still fires. Users should
///    set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.
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
