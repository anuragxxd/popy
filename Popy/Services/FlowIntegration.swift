import Foundation
import SQLite3

/// Reads Wispr Flow's local SQLite database to capture voice transcriptions
/// and feed them into Popy's clipboard history.
///
/// Wispr Flow stores every transcription in `~/Library/Application Support/Wispr Flow/flow.sqlite`
/// in a `History` table. We open it read-only and poll for new rows by timestamp.
///
/// The database uses WAL mode; opening with SQLITE_OPEN_READONLY handles this fine
/// as long as we don't need to write (we never do).
final class FlowIntegration {

    static let shared = FlowIntegration()

    // MARK: - Constants

    /// Path to Wispr Flow's SQLite database
    private let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/Wispr Flow/flow.sqlite"
    }()

    /// How often we check for new transcriptions (seconds)
    private let pollInterval: TimeInterval = 2.0

    // MARK: - State

    private var db: OpaquePointer?
    private var timer: Timer?

    /// Tracks the latest timestamp we've already seen so we only fetch new rows.
    /// Stored in UserDefaults so we don't re-import history across app restarts.
    private var lastSeenTimestamp: String {
        get {
            UserDefaults.standard.string(forKey: "flowLastSeenTimestamp") ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "flowLastSeenTimestamp")
        }
    }

    /// Called with each new transcription. ClipboardManager hooks into this.
    var onNewTranscription: ((ClipboardItem) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Returns true if Wispr Flow appears to be installed (the database file exists).
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// Start polling Wispr Flow's database for new transcriptions.
    func startMonitoring() {
        guard timer == nil else { return }

        guard openDatabase() else {
            print("Popy [Flow] Could not open Wispr Flow database — integration disabled")
            return
        }

        // On first launch with the integration, set the timestamp to "now" so we don't
        // import the entire history backlog. Users who want historical items can clear
        // the pref to trigger a full import.
        // Format must match Wispr Flow's: "2026-03-12 18:32:13.847 +00:00"
        if lastSeenTimestamp.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
            formatter.timeZone = TimeZone(identifier: "UTC")
            lastSeenTimestamp = formatter.string(from: Date())
        }

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollForNewTranscriptions()
        }
        if let timer = timer {
            RunLoop.current.add(timer, forMode: .common)
        }

        // Do an immediate check
        pollForNewTranscriptions()

        print("Popy [Flow] Monitoring started (polling every \(pollInterval)s)")
    }

    /// Stop monitoring and close the database connection.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        closeDatabase()
        print("Popy [Flow] Monitoring stopped")
    }

    // MARK: - Database

    private func openDatabase() -> Bool {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Popy [Flow] Database not found at: \(dbPath)")
            return false
        }

        // Open read-only — we never write to Wispr Flow's database
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(dbPath, &db, flags, nil)

        if result != SQLITE_OK {
            let errmsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            print("Popy [Flow] sqlite3_open_v2 failed: \(errmsg) (code \(result))")
            db = nil
            return false
        }

        // Set a short busy timeout so we don't block if Wispr Flow is writing
        sqlite3_busy_timeout(db, 500)

        return true
    }

    private func closeDatabase() {
        if let db = db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Polling

    private func pollForNewTranscriptions() {
        guard let db = db else {
            // Try to reconnect if the file appeared (e.g. Wispr Flow was just installed)
            if isAvailable {
                if openDatabase() {
                    pollForNewTranscriptions()
                }
            }
            return
        }

        // Query for rows newer than our last seen timestamp.
        // `formattedText` is the cleaned-up transcription (with AI formatting applied).
        // `status` = 'formatted' means the transcription completed successfully.
        let query = """
            SELECT transcriptEntityId, formattedText, timestamp, app
            FROM History
            WHERE timestamp > ? AND status = 'formatted'
              AND formattedText IS NOT NULL AND formattedText != ''
            ORDER BY timestamp ASC
            LIMIT 50
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            print("Popy [Flow] prepare failed: \(errmsg)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        // Bind the last-seen timestamp.
        // Use SQLITE_TRANSIENT (-1 cast) so SQLite copies the string immediately,
        // avoiding lifetime issues with Swift's String bridge.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, lastSeenTimestamp, -1, SQLITE_TRANSIENT)

        var newMaxTimestamp = lastSeenTimestamp

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let textPtr = sqlite3_column_text(stmt, 1),
                  let tsPtr = sqlite3_column_text(stmt, 2) else {
                continue
            }

            let formattedText = String(cString: textPtr)
            let timestampStr = String(cString: tsPtr)

            // Parse the timestamp from Wispr Flow's format: "2026-03-12 18:32:13.847 +00:00"
            let date = parseFlowTimestamp(timestampStr)

            // Track the maximum timestamp we've seen
            if timestampStr > newMaxTimestamp {
                newMaxTimestamp = timestampStr
            }

            let item = ClipboardItem(
                text: formattedText,
                timestamp: date,
                source: .wisprflow
            )

            onNewTranscription?(item)
        }

        // Update the watermark
        if newMaxTimestamp != lastSeenTimestamp {
            lastSeenTimestamp = newMaxTimestamp
        }
    }

    // MARK: - Timestamp Parsing

    /// Parses timestamps in the format "2026-03-12 18:32:13.847 +00:00"
    private func parseFlowTimestamp(_ str: String) -> Date {
        // Try the full format with fractional seconds and timezone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Wispr Flow uses: "2026-03-12 18:32:13.847 +00:00"
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        if let date = formatter.date(from: str) {
            return date
        }

        // Fallback: without fractional seconds
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        if let date = formatter.date(from: str) {
            return date
        }

        // Last resort: just use now
        print("Popy [Flow] Could not parse timestamp: \(str)")
        return Date()
    }

    // MARK: - Reset

    /// Clears the last-seen timestamp so the next poll re-imports all history.
    /// Useful for debugging.
    func resetWatermark() {
        lastSeenTimestamp = ""
    }
}
