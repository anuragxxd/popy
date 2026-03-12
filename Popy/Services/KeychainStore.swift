import Foundation
import Security

/// Persists clipboard history in the macOS Keychain.
///
/// Why Keychain instead of UserDefaults:
///   - Encrypted at rest by the OS (AES-256 via Secure Enclave on Apple Silicon)
///   - Access is scoped to this app's bundle ID — other processes cannot read it
///     without matching entitlements and explicit user approval
///   - Survives app deletion only if kSecAttrSynchronizable is set (we leave it off)
///
/// We store the entire history as a single JSON blob under one Keychain item,
/// keyed by `service + account`. This avoids per-item complexity while keeping
/// the total payload small (25 short text entries is well under the ~2KB soft limit;
/// we JSON-encode and check size before writing).
final class KeychainStore {

    static let shared = KeychainStore()

    private let service = "com.popy.app"
    private let account = "clipboard-history"

    /// UserDefaults key used in the old storage scheme — kept for migration only.
    private let legacyDefaultsKey = "clipboardHistory"

    private init() {}

    // MARK: - Read

    /// Load clipboard history from the Keychain.
    /// Returns an empty array if nothing is stored yet.
    func load() -> [ClipboardItem] {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                print("Popy [Keychain] load error: \(status)")
            }
            return []
        }

        do {
            return try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            print("Popy [Keychain] decode error: \(error)")
            return []
        }
    }

    // MARK: - Write

    /// Save clipboard history to the Keychain.
    /// Uses SecItemUpdate if an item already exists, SecItemAdd otherwise.
    func save(_ items: [ClipboardItem]) {
        guard let data = try? JSONEncoder().encode(items) else {
            print("Popy [Keychain] encode error")
            return
        }

        // Warn if payload is unexpectedly large (shouldn't happen with 25 short strings)
        if data.count > 4096 {
            print("Popy [Keychain] warning: payload is \(data.count) bytes")
        }

        let exists = itemExists()

        if exists {
            let query: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let attributes: [CFString: Any] = [
                kSecValueData: data
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status != errSecSuccess {
                print("Popy [Keychain] update error: \(status)")
            }
        } else {
            let query: [CFString: Any] = [
                kSecClass:                kSecClassGenericPassword,
                kSecAttrService:          service,
                kSecAttrAccount:          account,
                kSecAttrLabel:            "Popy Clipboard History",
                kSecAttrDescription:      "Recent clipboard entries managed by Popy",
                // Only accessible when device is unlocked — not backed up to iCloud
                kSecAttrAccessible:       kSecAttrAccessibleWhenUnlocked,
                kSecValueData:            data
            ]
            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess {
                print("Popy [Keychain] add error: \(status)")
            }
        }
    }

    // MARK: - Delete

    /// Wipe all clipboard history from the Keychain.
    func deleteAll() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Popy [Keychain] delete error: \(status)")
        }
    }

    // MARK: - Migration from UserDefaults

    /// One-time migration: moves any existing history from UserDefaults into the
    /// Keychain, then removes the plaintext UserDefaults entry.
    func migrateFromUserDefaultsIfNeeded() {
        // Only migrate if Keychain is empty and UserDefaults has data
        guard !itemExists(),
              let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let items = try? JSONDecoder().decode([ClipboardItem].self, from: data),
              !items.isEmpty else {
            return
        }

        save(items)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        print("Popy [Keychain] migrated \(items.count) items from UserDefaults")
    }

    // MARK: - Helpers

    private func itemExists() -> Bool {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
            kSecReturnData:   false,
            kSecMatchLimit:   kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
