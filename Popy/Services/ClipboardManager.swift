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

        record(copiedString)
    }

    /// Insert `text` at the top of the history, de-duplicating and capping.
    private func record(_ text: String) {
        // Deduplicate: skip if it matches the most recent item
        if let mostRecent = items.first, mostRecent.text == text {
            return
        }

        // Remove any older duplicate (move to top rather than creating a second entry)
        items.removeAll { $0.text == text }

        items.insert(ClipboardItem(text: text), at: 0)

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

    // MARK: - Dictation

    /// Place a voice transcript on the clipboard verbatim and add it to history.
    ///
    /// The text is written byte-for-byte as the speech engine produced it —
    /// no trimming, casing, or reformatting beyond what the engine did.
    /// We record it directly rather than letting the poller notice it so the
    /// entry appears instantly instead of up to `pollInterval` later.
    func copyTranscript(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        record(text)
    }

    /// Put a transcript on the clipboard only long enough to paste it, then
    /// put back whatever was there before. It is still added to history.
    ///
    /// A simulated Cmd+V is queued, so nothing reports when the target app
    /// has read the clipboard; `delay` is a safety margin, not a signal. If
    /// anything else is copied in the meantime, that is kept instead.
    func copyTranscriptBriefly(_ text: String, restoringAfter delay: TimeInterval) {
        let pasteboard = NSPasteboard.general

        // Dictating again before the last restore ran: the clipboard still
        // holds that transcript, so keep what the user had before either.
        let previous: [Formats]
        if let pending = pendingRestore, pending.changeCount == pasteboard.changeCount {
            previous = pending.contents
        } else {
            previous = contents(of: pasteboard)
        }

        // Kept off the user's other devices, and marked so other clipboard
        // managers do not record it (https://nspasteboard.org).
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
        record(text)

        let restore = PendingRestore(contents: previous, changeCount: pasteboard.changeCount)
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.pendingRestore?.changeCount == restore.changeCount else { return }
            self.pendingRestore = nil
            guard pasteboard.changeCount == restore.changeCount else { return }
            self.write(restore.contents, to: pasteboard)
            // Not a new copy, so keep the poller from recording it again.
            self.lastChangeCount = pasteboard.changeCount
        }
    }

    /// Add a voice transcript to history without touching the clipboard.
    func saveTranscript(_ text: String) {
        record(text)
    }

    // MARK: - Restoring

    /// One clipboard entry in every format it was offered in, in order.
    private typealias Formats = [(type: NSPasteboard.PasteboardType, data: Data)]

    /// What the clipboard held before a transcript was pasted through it,
    /// and the change count at which the transcript is still sitting there.
    private struct PendingRestore {
        let contents: [Formats]
        let changeCount: Int
    }

    private var pendingRestore: PendingRestore?

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Everything on the pasteboard, in every format, so it can be put back
    /// exactly — rich text, images, and files as well as plain text.
    private func contents(of pasteboard: NSPasteboard) -> [Formats] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    private func write(_ contents: [Formats], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = contents.map { formats -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in formats {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - Clear

    /// Clear all clipboard history from memory and Keychain.
    func clearAll() {
        items.removeAll()
        KeychainStore.shared.deleteAll()
        onUpdate?()
    }
}
