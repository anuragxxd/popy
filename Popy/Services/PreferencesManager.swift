import Foundation

/// Manages user preferences stored in UserDefaults.
final class PreferencesManager {

    static let shared = PreferencesManager()

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Click Behavior

    enum ClickBehavior: String {
        case copyToClipboard = "copyToClipboard"
        case pasteDirectly = "pasteDirectly"
    }

    /// What happens when you click a clipboard history item.
    /// Default: copyToClipboard
    var clickBehavior: ClickBehavior {
        get {
            guard let raw = defaults.string(forKey: "clickBehavior"),
                  let value = ClickBehavior(rawValue: raw) else {
                return .copyToClipboard
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: "clickBehavior")
        }
    }

    // MARK: - Sound on Copy

    /// Whether to play a subtle sound when an item is re-copied.
    /// Default: false
    var soundEnabled: Bool {
        get { defaults.bool(forKey: "soundEnabled") }
        set { defaults.set(newValue, forKey: "soundEnabled") }
    }

    // MARK: - Voice Input

    /// Whether double-tapping Fn starts voice dictation.
    /// Default: true
    var voiceInputEnabled: Bool {
        get {
            if defaults.object(forKey: "voiceInputEnabled") == nil { return true }
            return defaults.bool(forKey: "voiceInputEnabled")
        }
        set { defaults.set(newValue, forKey: "voiceInputEnabled") }
    }

    /// Whether a finished transcript is also pasted into the focused app.
    /// Default: false — clipboard only.
    var voicePasteDirectly: Bool {
        get { defaults.bool(forKey: "voicePasteDirectly") }
        set { defaults.set(newValue, forKey: "voicePasteDirectly") }
    }

    /// Whether system audio output is silenced while recording, so whatever is
    /// playing does not bleed into the microphone.
    /// Default: true
    var muteWhileDictating: Bool {
        get {
            if defaults.object(forKey: "muteWhileDictating") == nil { return true }
            return defaults.bool(forKey: "muteWhileDictating")
        }
        set { defaults.set(newValue, forKey: "muteWhileDictating") }
    }
}
