import Foundation
import Security

/// Keychain wrapper for FalMac. Stores one API key per named "profile" so the
/// user can switch between Personal / Team / Work keys without retyping.
///
/// Layout in the keychain:
/// - service: `ai.fal.FalMac`
/// - account: `<profile name>` (e.g. "Personal", "Team")
/// - data: UTF-8 encoded fal.ai key string
///
/// Backwards compat: the original single-key flow stored the value under
/// account="api_key". `migrateLegacyIfNeeded()` moves it to a "Default"
/// profile the first time the app launches under the multi-key code.
enum Keychain {
    private static let service = "ai.fal.FalMac"
    private static let legacyAccount = "api_key"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Return all account names (profile names) currently stored.
    static func allProfiles() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let array = item as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0 != legacyAccount }
            .sorted()
    }

    /// On first launch under the multi-key scheme, copy the legacy
    /// `api_key` entry into a "Default" profile so nothing's lost.
    static func migrateLegacyIfNeeded() -> String? {
        guard let legacy = get(legacyAccount) else { return nil }
        let target = "Default"
        if get(target) == nil { set(legacy, account: target) }
        remove(legacyAccount)
        return target
    }
}
