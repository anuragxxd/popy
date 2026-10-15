import AppKit
import Carbon.HIToolbox

/// Simulates keyboard events to paste into the frontmost application.
/// Requires Accessibility permissions (System Preferences → Privacy → Accessibility).
enum KeyboardSimulator {

    /// Simulate Cmd+V (paste) into whatever app is currently focused.
    /// The caller should have already placed the desired text on NSPasteboard.
    ///
    /// Sent as a full Command press around the V, the way a person types it.
    /// A lone V event carrying the Command flag is enough for most apps, but
    /// some (Electron and Java apps, remote desktops, VMs) track modifier state
    /// from the Command key events themselves and see just a "v".
    static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command = CGKeyCode(kVK_Command)
        let v = keyCodeForV()

        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else {
            print("Popy: Failed to create CGEvent for paste simulation.")
            return
        }

        // Explicit flags, so a modifier the user is still holding (Option, for
        // one) cannot turn this into a different shortcut.
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []

        // A few milliseconds apart: back-to-back events can arrive in one
        // batch, and some apps then drop the key press.
        for event in [commandDown, keyDown, keyUp, commandUp] {
            event.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    /// The key that types "v" with Command held in the current layout.
    ///
    /// Shortcuts follow the layout, not the key's position: on Dvorak the
    /// ANSI "V" key types "k", so posting `kVK_ANSI_V` would send Cmd+K.
    /// Layouts like "Dvorak – QWERTY ⌘" switch to QWERTY while Command is
    /// down, which is why the lookup is done with Command held. Falls back to
    /// the ANSI position when the layout has no "v" (Russian, Greek…), where
    /// apps match shortcuts by that position anyway.
    private static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return fallback }

            let commandState = UInt32((cmdKey >> 8) & 0xFF)
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0

            // The ANSI position first: it is the answer on most layouts.
            let candidates = [fallback] + (0..<128).map(CGKeyCode.init).filter { $0 != fallback }
            for keyCode in candidates {
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    commandState,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                if status == noErr, length == 1, characters[0] == UniChar(("v" as Unicode.Scalar).value) {
                    return keyCode
                }
            }
            return fallback
        }
    }

    /// Check if we have Accessibility permissions (needed for CGEvent posting).
    static var hasAccessibilityPermission: Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permissions.
    /// Opens System Preferences to the right pane.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
