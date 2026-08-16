import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private let clipboardManager = ClipboardManager.shared
    private let loginItemManager = LoginItemManager.shared
    private let preferences = PreferencesManager.shared
    private let updateManager = UpdateManager.shared
    private let hotkeyManager = HotkeyManager.shared
    private let voiceController = VoiceInputController.shared

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If a previous run was killed mid-recording it may have left system
        // audio muted. Put it back before anything else.
        SystemAudioMuter.shared.restoreAfterUnexpectedExit()

        installScreenCaptureProtection()
        setupStatusItem()
        buildMenu()

        clipboardManager.onUpdate = { [weak self] in
            self?.buildMenu()
        }
        clipboardManager.startMonitoring()

        hotkeyManager.onHotkey = { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
        hotkeyManager.register()

        // Keep the icon, the Start/Stop label, and the diagnostics in sync.
        voiceController.onStateChange = { [weak self] state in
            self?.updateStatusIcon(for: state)
            self?.buildMenu()
        }
        voiceController.onNotify = { [weak self] message in
            self?.showAlert(title: "Voice Input", message: message, showDownload: false)
        }
        voiceController.start()

        // Accessibility is required only to *post* CGEvents — i.e. the two
        // paste paths. It is NOT needed for the Fn listener, so we no longer
        // prompt merely because voice input is on.
        //
        // We do prompt when a paste mode is already enabled, because that mode
        // fails silently without it: CGEvent.post() is a no-op, the text sits
        // on the clipboard, and nothing indicates why nothing was pasted.
        let pasteEnabled = preferences.clickBehavior == .pasteDirectly || preferences.voicePasteDirectly
        if pasteEnabled, !KeyboardSimulator.hasAccessibilityPermission {
            KeyboardSimulator.requestAccessibilityPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        clipboardManager.stopMonitoring()
        hotkeyManager.unregister()
        voiceController.stop()
        // Belt and braces — voiceController.stop() already restores, but audio
        // must never be left muted.
        SystemAudioMuter.shared.restore()
    }

    // MARK: - Screen Capture Protection

    private func installScreenCaptureProtection() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectWindowFromScreenCapture(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectWindowFromScreenCapture(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        protectAppWindowsFromScreenCapture()
    }

    @objc private func protectWindowFromScreenCapture(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        protectFromScreenCapture(window)
    }

    private func protectAppWindowsFromScreenCapture() {
        NSApp.windows.forEach(protectFromScreenCapture)
    }

    private func protectFromScreenCapture(_ window: NSWindow) {
        // Prevent Popy UI (menus, alerts, and any future windows) from being
        // included in screen recordings or screen-sharing captures.
        window.sharingType = .none
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(for: .idle)
    }

    /// Reflect the dictation state in the menu bar. This is the only feedback
    /// the user gets that recording is live, so it must always be accurate.
    private func updateStatusIcon(for state: VoiceInputController.State) {
        guard let button = statusItem?.button else { return }

        let symbol: String
        let tint: NSColor?
        let tooltip: String

        switch state {
        case .idle:
            symbol = "doc.on.clipboard"
            tint = nil
            tooltip = "Popy — Clipboard History"
        case .recording:
            symbol = "mic.fill"
            tint = .systemRed
            tooltip = "Popy — Listening… (press Fn twice to stop)"
        case .transcribing:
            symbol = "waveform"
            tint = .secondaryLabelColor
            tooltip = "Popy — Transcribing…"
        }

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "Popy"
        }
        button.contentTintColor = tint
        button.toolTip = tooltip
    }

    // MARK: - Menu Construction

    func buildMenu() {
        // Repopulate the existing menu in place rather than swapping in a new
        // NSMenu. Replacing `statusItem.menu` while the menu is opening (which
        // `menuNeedsUpdate` does) leaves AppKit displaying the old object.
        let menu = statusItem.menu ?? NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.removeAllItems()

        // ── Clipboard history items ──────────────────────────
        let items = clipboardManager.items
        if items.isEmpty {
            let emptyItem = NSMenuItem(title: "No clipboard history yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (index, item) in items.enumerated() {
                let menuItem = NSMenuItem(
                    title: "",
                    action: #selector(clipboardItemClicked(_:)),
                    keyEquivalent: ""
                )
                menuItem.tag = index
                menuItem.target = self

                let fullString = NSMutableAttributedString()

                let textPart = NSAttributedString(
                    string: item.truncatedText(),
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                        .foregroundColor: NSColor.labelColor
                    ]
                )
                fullString.append(textPart)

                let timePart = NSAttributedString(
                    string: "  · \(item.relativeTimestamp())",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]
                )
                fullString.append(timePart)

                menuItem.attributedTitle = fullString
                menu.addItem(menuItem)
            }
        }

        // ── Clear All ────────────────────────────────────────
        if !items.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear All History", action: #selector(clearAllClicked(_:)), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        // ── Preferences section ──────────────────────────────
        menu.addItem(NSMenuItem.separator())

        // Toggle 1: Click behavior (Copy to Clipboard / Paste Directly)
        let isPasteDirect = preferences.clickBehavior == .pasteDirectly

        let copyModeItem = NSMenuItem(title: "Click to Copy", action: #selector(setClickToCopy(_:)), keyEquivalent: "")
        copyModeItem.target = self
        copyModeItem.state = isPasteDirect ? .off : .on
        menu.addItem(copyModeItem)

        let pasteModeItem = NSMenuItem(title: "Click to Paste Directly", action: #selector(setClickToPaste(_:)), keyEquivalent: "")
        pasteModeItem.target = self
        pasteModeItem.state = isPasteDirect ? .on : .off
        menu.addItem(pasteModeItem)

        // Pasting posts CGEvents, which needs Accessibility. Without it the
        // copy still succeeds but the paste silently does nothing — so say so
        // rather than letting the user think the app is broken.
        if isPasteDirect, !KeyboardSimulator.hasAccessibilityPermission {
            let text = "⚠ Needs Accessibility — click to grant"
            let warning = NSMenuItem(title: text, action: #selector(grantAccessibility(_:)), keyEquivalent: "")
            warning.target = self
            warning.attributedTitle = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.systemOrange
                ]
            )
            menu.addItem(warning)
        }

        menu.addItem(NSMenuItem.separator())

        // Toggle 2: Sound on copy
        let soundItem = NSMenuItem(title: "Sound on Copy", action: #selector(toggleSound(_:)), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = preferences.soundEnabled ? .on : .off
        menu.addItem(soundItem)

        // Toggle 3: Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        // ── Voice input ──────────────────────────────────────
        menu.addItem(NSMenuItem.separator())

        let voiceHeader = NSMenuItem(title: "Voice Input", action: nil, keyEquivalent: "")
        voiceHeader.isEnabled = false
        voiceHeader.attributedTitle = NSAttributedString(
            string: "Voice Input",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        menu.addItem(voiceHeader)

        // Explicit trigger — works even when the Fn listener does not.
        let isBusy = voiceController.state != .idle
        let dictateNow = NSMenuItem(
            title: isBusy ? "Stop Dictation" : "Start Dictation",
            action: #selector(startDictation(_:)),
            keyEquivalent: ""
        )
        dictateNow.target = self
        dictateNow.isEnabled = preferences.voiceInputEnabled
        menu.addItem(dictateNow)

        let voiceToggle = NSMenuItem(title: "Dictate with Fn Fn", action: #selector(toggleVoiceInput(_:)), keyEquivalent: "")
        voiceToggle.target = self
        voiceToggle.state = preferences.voiceInputEnabled ? .on : .off
        menu.addItem(voiceToggle)

        let voicePasteItem = NSMenuItem(title: "Paste Transcript Directly", action: #selector(toggleVoicePaste(_:)), keyEquivalent: "")
        voicePasteItem.target = self
        voicePasteItem.state = preferences.voicePasteDirectly ? .on : .off
        voicePasteItem.isEnabled = preferences.voiceInputEnabled
        menu.addItem(voicePasteItem)

        let muteItem = NSMenuItem(title: "Mute Audio While Dictating", action: #selector(toggleMuteWhileDictating(_:)), keyEquivalent: "")
        muteItem.target = self
        muteItem.state = preferences.muteWhileDictating ? .on : .off
        muteItem.isEnabled = preferences.voiceInputEnabled
        menu.addItem(muteItem)

        // Surface setup state. Every one of these failure modes is otherwise
        // silent, which is exactly what makes voice input feel "broken".
        if preferences.voiceInputEnabled {
            for problem in voiceDiagnostics() {
                let item = NSMenuItem(title: problem, action: #selector(openVoiceHelp(_:)), keyEquivalent: "")
                item.target = self
                item.attributedTitle = NSAttributedString(
                    string: problem,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.systemOrange
                    ]
                )
                menu.addItem(item)
            }
        }

        // ── Updates & Quit ────────────────────────────────────
        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let versionItem = NSMenuItem(title: "v\(updateManager.currentVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        let versionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        versionItem.attributedTitle = NSAttributedString(string: "v\(updateManager.currentVersion)", attributes: versionAttributes)
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Popy", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        protectAppWindowsFromScreenCapture()
    }

    /// Called immediately before the menu is displayed. Permissions, engine
    /// state, and model availability can all change while the app is running,
    /// so the diagnostics have to be recomputed here — previously they were
    /// frozen from whenever `buildMenu()` last happened to run, which meant a
    /// resolved problem could keep showing a warning indefinitely.
    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        protectAppWindowsFromScreenCapture()
        DispatchQueue.main.async { [weak self] in
            self?.protectAppWindowsFromScreenCapture()
        }
    }

    // MARK: - Menu Actions

    @objc private func clipboardItemClicked(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index >= 0, index < clipboardManager.items.count else { return }
        let item = clipboardManager.items[index]

        // Always copy to clipboard first
        clipboardManager.copyToClipboard(item)

        if preferences.soundEnabled {
            NSSound(named: .init("Tink"))?.play()
        }

        if preferences.clickBehavior == .pasteDirectly {
            // Small delay to let the menu close and the previous app regain focus.
            // CGEvent.post is a no-op if Accessibility isn't granted — the copy
            // to clipboard still happened, so the user can Cmd+V manually.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                KeyboardSimulator.simulatePaste()
            }
        }
    }

    @objc private func clearAllClicked(_ sender: NSMenuItem) {
        clipboardManager.clearAll()
    }

    @objc private func setClickToCopy(_ sender: NSMenuItem) {
        preferences.clickBehavior = .copyToClipboard
        buildMenu()
    }

    @objc private func setClickToPaste(_ sender: NSMenuItem) {
        // Check accessibility before enabling paste-directly mode
        if !KeyboardSimulator.hasAccessibilityPermission {
            KeyboardSimulator.requestAccessibilityPermission()
        }
        preferences.clickBehavior = .pasteDirectly
        buildMenu()
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        preferences.soundEnabled.toggle()
        buildMenu()
    }

    /// Everything that would actually stop dictation from working.
    ///
    /// Deliberately does NOT gate the Fn listener on `AXIsProcessTrusted()`.
    /// Two reasons, both verified on this machine:
    ///
    ///  1. `.flagsChanged` monitoring needs neither Accessibility nor Input
    ///     Monitoring, so the check was irrelevant to begin with.
    ///  2. `AXIsProcessTrusted()` is unreliable for an ad-hoc signed app.
    ///     TCC stores a code-signature requirement (`cdhash H"..."`), and every
    ///     rebuild changes the cdhash — so the API reports false while System
    ///     Settings still shows the app ticked. Warning off that produced a
    ///     permanent, wrong "Accessibility off" message.
    ///
    /// Accessibility is only genuinely required to *post* events, i.e. pasting.
    private func voiceDiagnostics() -> [String] {
        var problems: [String] = []

        if TranscriptionService.resolveBinary() == nil {
            problems.append("⚠ Engine missing — reinstall Popy")
        } else if !TranscriptionService.isModelInstalled {
            problems.append("⚠ Model not downloaded — start dictation once")
        }

        if AudioRecorder.microphoneAuthorization == .denied
            || AudioRecorder.microphoneAuthorization == .restricted {
            problems.append("⚠ Microphone denied — enable it in Privacy settings")
        }

        // Only surface the key listener if it has genuinely never seen an
        // event. Any Shift or Command press sets this, so on a working system
        // it clears within seconds of normal typing.
        if preferences.voiceInputEnabled,
           FnKeyListener.shared.isRunning,
           !FnKeyListener.shared.isReceivingEvents {
            problems.append("⚠ Fn key not detected yet — or use Start Dictation above")
        }

        // Pasting posts CGEvents, which really does need Accessibility.
        if preferences.voicePasteDirectly, !KeyboardSimulator.hasAccessibilityPermission {
            problems.append("⚠ Paste Directly needs Accessibility — remove and re-add Popy")
        }

        return problems
    }

    @objc private func startDictation(_ sender: NSMenuItem) {
        voiceController.toggleDictation()
    }

    @objc private func grantAccessibility(_ sender: NSMenuItem) {
        KeyboardSimulator.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openVoiceHelp(_ sender: NSMenuItem) {
        // Send the user to the pane that fixes whichever problem is live.
        if AudioRecorder.microphoneAuthorization != .authorized {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        } else if preferences.voicePasteDirectly, !KeyboardSimulator.hasAccessibilityPermission {
            KeyboardSimulator.requestAccessibilityPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func toggleVoiceInput(_ sender: NSMenuItem) {
        let enabling = !preferences.voiceInputEnabled
        voiceController.setEnabled(enabling)

        // Global keyboard monitoring is dead without Accessibility, and it
        // fails silently, so ask up front rather than letting Fn Fn do nothing.
        if enabling, !KeyboardSimulator.hasAccessibilityPermission {
            KeyboardSimulator.requestAccessibilityPermission()
        }
        buildMenu()
    }

    @objc private func toggleMuteWhileDictating(_ sender: NSMenuItem) {
        preferences.muteWhileDictating.toggle()
        // If it is switched off mid-recording, unmute immediately rather than
        // waiting for the recording to finish.
        if !preferences.muteWhileDictating {
            SystemAudioMuter.shared.restore()
        }
        buildMenu()
    }

    @objc private func toggleVoicePaste(_ sender: NSMenuItem) {
        let enabling = !preferences.voicePasteDirectly
        if enabling, !KeyboardSimulator.hasAccessibilityPermission {
            KeyboardSimulator.requestAccessibilityPermission()
        }
        preferences.voicePasteDirectly = enabling
        buildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !loginItemManager.isEnabled
        loginItemManager.setEnabled(newState)
        buildMenu()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updateManager.checkForUpdates { [weak self] result in
            guard self != nil else { return }
            switch result {
            case .upToDate:
                self?.showAlert(
                    title: "You're up to date",
                    message: "Popy v\(UpdateManager.shared.currentVersion) is the latest version.",
                    showDownload: false
                )
            case .updateAvailable(let latestVersion, let downloadURL):
                self?.showAlert(
                    title: "Update available",
                    message: "Popy v\(latestVersion) is available (you have v\(UpdateManager.shared.currentVersion)).",
                    showDownload: true,
                    downloadURL: downloadURL
                )
            case .error(let message):
                self?.showAlert(
                    title: "Update check failed",
                    message: message,
                    showDownload: false
                )
            }
        }
    }

    private func showAlert(title: String, message: String, showDownload: Bool, downloadURL: String? = nil) {
        // Bring our process to front so the alert is visible (we're an LSUIElement app)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.window.sharingType = .none

        if showDownload, let urlString = downloadURL {
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}
