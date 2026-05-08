import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private let clipboardManager = ClipboardManager.shared
    private let loginItemManager = LoginItemManager.shared
    private let preferences = PreferencesManager.shared
    private let updateManager = UpdateManager.shared
    private let hotkeyManager = HotkeyManager.shared

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager.stopMonitoring()
        hotkeyManager.unregister()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Popy Clipboard History") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Popy"
            }
            button.toolTip = "Popy — Clipboard History"
        }
    }

    // MARK: - Menu Construction

    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

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
            // Need accessibility permission for CGEvent simulation
            if KeyboardSimulator.hasAccessibilityPermission {
                // Small delay to let the menu close and the previous app regain focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    KeyboardSimulator.simulatePaste()
                }
            } else {
                // Prompt for permission — the copy still happened, just no auto-paste
                KeyboardSimulator.requestAccessibilityPermission()
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
