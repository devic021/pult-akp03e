import Foundation
import Security

/// A small wrapper over the login keychain, one secret per account.
///
/// The Home Assistant token is the one thing Pult keeps that is worth hiding:
/// it grants full control of a home. It belongs here rather than in the
/// configuration file or a shell script, both of which are round-tripped,
/// backed up and pasted into bug reports.
enum Keychain {
    /// The service every Pult secret is filed under, so they are easy to find
    /// and to clear, and never collide with another app's items.
    static let service = "dev.pult.secrets"

    /// Stores or replaces the secret under `account`; a nil secret removes it.
    /// Returns whether the keychain accepted the change.
    @discardableResult
    static func set(_ secret: String?, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        guard let secret, !secret.isEmpty, let data = secret.data(using: .utf8) else {
            return true
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// The secret under `account`, or nil if there is none.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
