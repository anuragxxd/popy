import AppKit

/// Monitors the system clipboard for changes, persists history via Keychain,
/// and provides re-copy. History is stored in the macOS Keychain (encrypted at
/// rest, app-scoped) rather than plaintext UserDefaults.
final class ClipboardManager {

    // MARK: - Constants

    static let shared = ClipboardManager()
    private let maxItems = 25
    private let pollInterval: TimeInterval = 0.5

    // MARK: - State

    private(set) var items: [ClipboardItem] = []
    private var lastChangeCount: Int
    private var timer: Timer?

    /// Called whenever the items array changes. The menu controller hooks into this.
    var onUpdate: (() -> Void)?

    // MARK: - Init

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        // Migrate any old UserDefaults history into Keychain on first run
        KeychainStore.shared.migrateFromUserDefaultsIfNeeded()
        items = KeychainStore.shared.load()
    }

    // MARK: - Polling

    /// Start monitoring the clipboard.
    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        // Ensure timer fires even while a menu is open
        if let timer = timer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    /// Stop monitoring the clipboard.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkForChanges() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        guard let copiedString = pasteboard.string(forType: .string),
              !copiedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Deduplicate: skip if it matches the most recent item
        if let mostRecent = items.first, mostRecent.text == copiedString {
            return
        }

        // Remove any older duplicate (move to top rather than creating a second entry)
        items.removeAll { $0.text == copiedString }

        items.insert(ClipboardItem(text: copiedString), at: 0)

        // Cap at max items
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        KeychainStore.shared.save(items)
        onUpdate?()
    }

    // MARK: - External Item Insertion (used by FlowIntegration)

    /// Insert a clipboard item from an external source (e.g. Wispr Flow).
    /// Handles deduplication against existing entries.
    func insertExternalItem(_ item: ClipboardItem) {
        // Skip empty text
        guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Deduplicate: skip if it matches the most recent item
        if let mostRecent = items.first, mostRecent.text == item.text {
            return
        }

        // Remove any older duplicate
        items.removeAll { $0.text == item.text }

        items.insert(item, at: 0)

        // Cap at max items
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        KeychainStore.shared.save(items)
        onUpdate?()
    }

    // MARK: - Re-copy

    /// Copy a history item back onto the system clipboard.
    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        // Sync changeCount so we don't re-detect our own paste as a new entry
        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Clear

    /// Clear all clipboard history from memory and Keychain.
    func clearAll() {
        items.removeAll()
        KeychainStore.shared.deleteAll()
        onUpdate?()
    }
}
