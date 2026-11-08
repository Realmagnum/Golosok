import Foundation
import Security

/// Безопасное хранилище секретов (API-ключей, токенов) в Apple Keychain.
/// С автоматической миграцией ранее сохранённых ключей из открытого UserDefaults.
enum KeyStore {
    private static let serviceName = Bundle.main.bundleIdentifier ?? "kozak-developer.Golosok"
    private static let legacyPrefix = "keystore."

    static func set(_ value: String, for key: String) {
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanValue.isEmpty {
            delete(key)
            return
        }

        // Удаляем из открытого UserDefaults (если был)
        UserDefaults.standard.removeObject(forKey: legacyPrefix + key)

        guard let data = cleanValue.data(using: .utf8) else { return }

        // Проверяем наличие в Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8) {
            return str
        }

        // Проверяем legacy UserDefaults и мигрируем в Keychain
        if let legacy = UserDefaults.standard.string(forKey: legacyPrefix + key), !legacy.isEmpty {
            set(legacy, for: key)
            return legacy
        }

        return nil
    }

    static func delete(_ key: String) {
        UserDefaults.standard.removeObject(forKey: legacyPrefix + key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Миграция всех известных ключей из UserDefaults в Keychain при запуске
    static func migrateAllIfNeeded() {
        let allDefaults = UserDefaults.standard.dictionaryRepresentation()
        for (k, v) in allDefaults where k.hasPrefix(legacyPrefix) {
            let key = String(k.dropFirst(legacyPrefix.count))
            if let strVal = v as? String, !strVal.isEmpty {
                set(strVal, for: key)
            } else {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }
}
