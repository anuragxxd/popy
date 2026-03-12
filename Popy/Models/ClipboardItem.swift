import Foundation

/// Where a clipboard item originated from.
enum ClipboardSource: String, Codable {
    case clipboard   = "clipboard"
    case wisprflow   = "wisprflow"
}

/// A single clipboard history entry.
struct ClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let source: ClipboardSource

    init(text: String, source: ClipboardSource = .clipboard) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.source = source
    }

    init(text: String, timestamp: Date, source: ClipboardSource) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.source = source
    }

    // MARK: - Backward-compatible Codable

    enum CodingKeys: String, CodingKey {
        case id, text, timestamp, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        // Old items stored before the Flow integration won't have a "source" key
        source = try container.decodeIfPresent(ClipboardSource.self, forKey: .source) ?? .clipboard
    }

    /// Returns the text truncated to `maxLength` characters with ellipsis if needed.
    /// Newlines are collapsed to spaces and whitespace is trimmed before truncation.
    func truncatedText(maxLength: Int = 25) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= maxLength {
            return cleaned
        }
        return String(cleaned.prefix(maxLength)) + "..."
    }

    // MARK: - Formatting

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Returns a human-readable relative timestamp like "2m ago", "1h ago".
    func relativeTimestamp() -> String {
        return Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date())
    }
}
