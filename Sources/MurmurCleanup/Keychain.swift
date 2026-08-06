import Foundation
import Security

/// API keys live in the Keychain, never in UserDefaults or a plist.
/// The value is never logged, and only ever read at request time.
public enum Keychain {
    private static let service = "com.torimi.murmur"

    public static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            markPresence(false, for: account)
            return
        }
        markPresence(true, for: account)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a value was stored, *without* reading it.
    ///
    /// Reading the Keychain can raise a modal authorisation prompt — fine at
    /// request time, unacceptable for drawing a settings pane. This records the
    /// fact of a key separately so the UI never has to touch the secret.
    public static func isPresent(_ account: String) -> Bool {
        UserDefaults.standard.bool(forKey: "com.torimi.murmur.has." + account)
    }

    private static func markPresence(_ present: Bool, for account: String) {
        UserDefaults.standard.set(present, forKey: "com.torimi.murmur.has." + account)
    }

    public static func has(_ account: String) -> Bool {
        get(account)?.isEmpty == false
    }
}
