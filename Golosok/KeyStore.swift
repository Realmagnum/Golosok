import Foundation
import Security

/// Безопасное хранилище секретов (API-ключей, токенов) в Apple Keychain с оперативным кэшированием в памяти.
/// Устраняет повторные запросы системного пароля при переключении между провайдерами и экранами настроек.
enum KeyStore {
    private static let serviceName = Bundle.main.bundleIdentifier ?? "kozak-developer.Golosok"
    private static let legacyPrefix = "keystore."

    private static var memoryCache: [String: String] = [:]
    private static var isPreloaded = false
    private static let lock = NSLock()

    /// Разово загружает все ключи приложения в оперативную память при первом обращении.
    /// За счёт единого запроса `kSecMatchLimitAll` macOS запрашивает доступ к хранилищу максимум один раз.
    private static func preloadAllIfNeeded() {
        guard !isPreloaded else { return }
        isPreloaded = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   let data = item[kSecValueData as String] as? Data,
                   let str = String(data: data, encoding: .utf8) {
                    memoryCache[account] = str
                }
            }
        }
    }

    static func set(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        preloadAllIfNeeded()

        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanValue.isEmpty {
            memoryCache.removeValue(forKey: key)
            deleteFromKeychain(key)
            return
        }

        memoryCache[key] = cleanValue
        UserDefaults.standard.removeObject(forKey: legacyPrefix + key)

        guard let data = cleanValue.data(using: .utf8) else { return }

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
        lock.lock()
        defer { lock.unlock() }

        preloadAllIfNeeded()

        // 1. Быстрый ответ из кэша памяти (0 системных промптов)
        if let cached = memoryCache[key] {
            return cached
        }

        // 2. Если в кэше нет, точечно проверяем Keychain на случай добавления извне
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
            memoryCache[key] = str
            return str
        }

        // 3. Проверяем legacy UserDefaults и мигрируем
        if let legacy = UserDefaults.standard.string(forKey: legacyPrefix + key), !legacy.isEmpty {
            memoryCache[key] = legacy
            UserDefaults.standard.removeObject(forKey: legacyPrefix + key)
            return legacy
        }

        return nil
    }

    static func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }

        preloadAllIfNeeded()
        memoryCache.removeValue(forKey: key)
        deleteFromKeychain(key)
    }

    private static func deleteFromKeychain(_ key: String) {
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
        lock.lock()
        defer { lock.unlock() }

        preloadAllIfNeeded()

        let allDefaults = UserDefaults.standard.dictionaryRepresentation()
        for (k, v) in allDefaults where k.hasPrefix(legacyPrefix) {
            let key = String(k.dropFirst(legacyPrefix.count))
            if let strVal = v as? String, !strVal.isEmpty {
                memoryCache[key] = strVal
                guard let data = strVal.data(using: .utf8) else { continue }
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceName,
                    kSecAttrAccount as String: key
                ]
                var newItem = query
                newItem[kSecValueData as String] = data
                newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(newItem as CFDictionary, nil)
            }
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}
