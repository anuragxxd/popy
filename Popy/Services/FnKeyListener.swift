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
    /// 400ms missed relaxed double-taps often enough that Fn Fn felt like it
    /// "sometimes does nothing"; Fn has no other meaning on its own once the
    /// system action is suppressed, so a wider window costs nothing.
    private let doubleTapWindow: TimeInterval = 0.5

    /// How long Fn must stay down before it counts as hold-to-talk rather
    /// than a tap, or the first half of a double-tap.
    private let holdThreshold: TimeInterval = 0.35

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Key presses, watched only while Fn is down, so Fn used as a modifier
    /// (Fn+arrow, Fn+F1…) is never mistaken for hold-to-talk. Global key-down
    /// monitoring needs Accessibility; without it this is simply never fired.
    private var keyDownMonitor: Any?

    private var lastPressTime: TimeInterval = 0
    private var fnIsDown = false
    private var holdTimer: Timer?
    private(set) var isHolding = false

    /// Set to true once we have actually observed an Fn event, which proves
    /// Accessibility permission is live.
    private(set) var isReceivingEvents = false

    /// Fired on the main queue when Fn is tapped twice in quick succession.
    var onDoubleTap: (() -> Void)?

    /// Fired on the main queue when Fn has been held past `holdThreshold`
    /// with no other key involved. Only fires while `holdToTalkEnabled`.
    var onHoldStart: (() -> Void)?

    /// Fired on the main queue when a hold ends. `cancelled` is true when
    /// another key was pressed during the hold — Fn was a modifier, not a
    /// request to dictate.
    var onHoldEnd: ((_ cancelled: Bool) -> Void)?

    var holdToTalkEnabled = false

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
        endHold(cancelled: true)
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
        guard event.keyCode == Self.fnKeyCode else {
            // Another modifier joined Fn (Fn+Ctrl…): Fn is a modifier here.
            if fnIsDown { interruptHold() }
            return
        }

        let isDown = event.modifierFlags.contains(.function)

        guard isDown else {
            fnIsDown = false
            endHold(cancelled: false)
            return
        }

        // Modifiers do not auto-repeat, so a second "down" without a "up" in
        // between means the release was never delivered (it can be lost while
        // another app holds Secure Input, for one). Count it as a fresh press:
        // previously this was treated as a repeat and the press was dropped,
        // which made Fn Fn silently need a third tap.
        if fnIsDown {
            Log.dictation.notice("Fn down without a release; treating as a new press")
            endHold(cancelled: true)
        }
        fnIsDown = true

        let now = event.timestamp
        let elapsed = now - lastPressTime

        if elapsed > 0, elapsed <= doubleTapWindow {
            // Reset so a third tap starts a fresh pair rather than
            // immediately re-triggering.
            lastPressTime = 0
            Log.dictation.notice("Fn double-tap (\(Int(elapsed * 1000))ms apart)")
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleTap?()
            }
        } else {
            lastPressTime = now
            beginHoldTimer()
        }
    }

    // MARK: - Hold to talk

    private func beginHoldTimer() {
        guard holdToTalkEnabled else { return }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            guard let self = self, self.fnIsDown else { return }
            self.holdTimer = nil
            self.isHolding = true
            // A hold is not the first half of a double-tap.
            self.lastPressTime = 0
            Log.dictation.notice("Fn hold started")
            self.onHoldStart?()
        }
        // .common so a hold still registers while Popy's menu is open.
        if let timer = holdTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // Only possible with Accessibility; see `keyDownMonitor`.
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
                self?.interruptHold()
            }
        }
    }

    /// Fn turned out to be a modifier for another key: never start a hold,
    /// and abandon one already under way.
    private func interruptHold() {
        lastPressTime = 0
        endHold(cancelled: true)
    }

    private func endHold(cancelled: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }

        guard isHolding else { return }
        isHolding = false
        Log.dictation.notice("Fn hold ended\(cancelled ? " (cancelled)" : "")")
        onHoldEnd?(cancelled)
    }
}

// MARK: - System Fn action

/// Suppresses the system's Fn (globe) action — the emoji picker by default —
/// while Popy is listening for Fn Fn.
///
/// This is the setting behind System Settings → Keyboard → "Press 🌐 key to"
/// (0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation).
/// Writing its preference (`AppleFnUsageType` in `com.apple.HIToolbox`) is
/// not enough: HIToolbox caches the value in each process, so running
/// processes never see a plain write. `TISUpdateFnUsageType` applies it
/// properly — it stores the preference, invalidates the cache, broadcasts the
/// change to all processes, and rewires the dictation shortcut when moving
/// to or from Start Dictation.
///
/// Both TIS calls are private HIToolbox exports, so they are looked up at
/// runtime: if a future macOS drops them, this does nothing rather than
/// stopping Popy from launching, and the user can still pick Do Nothing by hand.
///
/// The user's original choice is persisted before it is overridden, so it
/// survives a crash and is restored on the next clean stop.
enum FnSystemActionOverride {

    private typealias GetFnUsageType = @convention(c) () -> Int32
    private typealias UpdateFnUsageType = @convention(c) (Int32) -> Void

    private static let hiToolbox = dlopen(
        "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox",
        RTLD_LAZY
    )
    private static let getFnUsageType: GetFnUsageType? = symbol("TISGetFnUsageType")
    private static let updateFnUsageType: UpdateFnUsageType? = symbol("TISUpdateFnUsageType")

    private static let doNothing: Int32 = 0
    private static let validValues: ClosedRange<Int32> = 0...3

    /// Popy's own record of the user's value. Absent: nothing overridden.
    private static let savedKey = "savedAppleFnUsageType"

    static func apply() {
        guard let getFnUsageType = getFnUsageType,
              let updateFnUsageType = updateFnUsageType else { return }

        // The effective value, which resolves an unset preference to the
        // system default — so restoring it restores what the key actually did.
        let current = getFnUsageType()

        // Only record the original once — after a crash the current value is
        // already ours, and overwriting would lose the user's real setting.
        if current != doNothing, UserDefaults.standard.object(forKey: savedKey) == nil {
            UserDefaults.standard.set(Int(current), forKey: savedKey)
        }

        // Push even when the value already reads Do Nothing: other processes
        // may still hold a stale cached value from a plain preference write.
        updateFnUsageType(doNothing)
    }

    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Int else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)

        // Out-of-range values are 1.4.0's "unset" marker, which has no live
        // equivalent to restore.
        guard let updateFnUsageType = updateFnUsageType,
              let value = Int32(exactly: saved), validValues.contains(value) else { return }

        // If the user changed the setting themselves while Popy ran, theirs wins.
        guard storedValue() == doNothing else { return }
        updateFnUsageType(value)
    }

    /// The value on disk. Read through CFPreferences rather than
    /// `TISGetFnUsageType`, whose in-process cache can miss a change the user
    /// made in System Settings.
    private static func storedValue() -> Int32? {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? NSNumber)?.int32Value
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = hiToolbox, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
