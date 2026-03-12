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

    // MARK: - Wispr Flow Integration

    /// Whether the Wispr Flow integration is enabled.
    /// Default: true (auto-enabled if Wispr Flow is detected)
    var flowIntegrationEnabled: Bool {
        get {
            // Default to true if the key has never been set
            if defaults.object(forKey: "flowIntegrationEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "flowIntegrationEnabled")
        }
        set {
            defaults.set(newValue, forKey: "flowIntegrationEnabled")
        }
    }
}
