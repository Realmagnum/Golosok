import Foundation
import Security

/// Безопасное хранилище всех секретов (API-ключей, токенов) в Apple Keychain в виде единого пакета (Credentials Pack).
/// Запрашивает системный доступ к Keychain ровно 1 раз при старте приложения, после чего все секреты
/// кэшируются в оперативной памяти и переиспользуются во всех экранах (провайдеры, настройки, транскрибация)
/// без повторных системных диалогов авторизации.
enum KeyStore {
    private static let serviceName = Bundle.main.bundleIdentifier ?? "kozak-developer.Golosok"
    private static let packAccount = "credentials_pack"
    private static let packLabel = "Golosok Credentials"
    private static let legacyPrefix = "keystore."

    private static var memoryCache: [String: String] = [:]
    private static var isPreloaded = false
    private static let lock = NSRecursiveLock()

    /// Разово загружает единый пакет секретов при старте приложения.
    /// За счёт единого элемента в Keychain macOS запрашивает системный доступ максимум один раз.
    static func preloadAllIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        preloadAllIfNeededLocked()
    }

    private static func preloadAllIfNeededLocked() {
        guard !isPreloaded else { return }
        isPreloaded = true

        // 1. Попытка загрузить существующий единый пакет секретов
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: packAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                memoryCache = dict
            }
            // Проверяем и подчищаем остатки legacy UserDefaults, если они были
            if migrateUserDefaultsOnlyLocked() {
                savePackToKeychainLocked()
            }
            return
        }

        // 2. Если единый пакет еще не создан (errSecItemNotFound) — мигрируем разрозненные ключи в единый пак
        if status == errSecItemNotFound {
            var migratedAny = false

            // Поиск старых отдельных элементов Keychain (kSecAttrAccount != packAccount)
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]

            var legacyResult: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)

            if legacyStatus == errSecSuccess, let items = legacyResult as? [[String: Any]] {
                var oldAccountsToDelete: [String] = []

                for item in items {
                    guard let account = item[kSecAttrAccount as String] as? String,
                          account != packAccount else { continue }

                    // Считываем значение старого элемента
                    let readQuery: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: serviceName,
                        kSecAttrAccount as String: account,
                        kSecReturnData as String: true,
                        kSecMatchLimit as String: kSecMatchLimitOne
                    ]

                    var oldDataRef: CFTypeRef?
                    if SecItemCopyMatching(readQuery as CFDictionary, &oldDataRef) == errSecSuccess,
                       let oldData = oldDataRef as? Data,
                       let strVal = String(data: oldData, encoding: .utf8),
                       !strVal.isEmpty {
                        memoryCache[account] = strVal
                        migratedAny = true
                    }

                    oldAccountsToDelete.append(account)
                }

                // Удаляем старые разрозненные элементы из Keychain, чтобы они больше никогда не вызывали диалогов
                for account in oldAccountsToDelete {
                    deleteSingleItemFromKeychain(account)
                }
            }

            // Миграция из UserDefaults
            if migrateUserDefaultsOnlyLocked() {
                migratedAny = true
            }

            // Сохраняем объединенный пакет в Keychain, если были найдены секреты
            if migratedAny || !memoryCache.isEmpty {
                savePackToKeychainLocked()
            }
        }
    }

    /// Быстрое получение секрета из кэша памяти без повторных обращений к Keychain.
    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        preloadAllIfNeededLocked()
        return memoryCache[key]
    }

    /// Сохранение секрета в кэш и синхронизация единого пакета в Keychain.
    static func set(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        preloadAllIfNeededLocked()

        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanValue.isEmpty {
            memoryCache.removeValue(forKey: key)
        } else {
            memoryCache[key] = cleanValue
        }

        UserDefaults.standard.removeObject(forKey: legacyPrefix + key)
        savePackToKeychainLocked()
    }

    /// Удаление секрета из единого пакета.
    static func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }

        preloadAllIfNeededLocked()

        memoryCache.removeValue(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyPrefix + key)
        savePackToKeychainLocked()
    }

    /// Сохраняет весь словарь memoryCache в единственный элемент Keychain.
    private static func savePackToKeychainLocked() {
        guard let data = try? JSONEncoder().encode(memoryCache) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: packAccount
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrLabel as String] = packLabel
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    /// Удаление старого единичного элемента Keychain при миграции.
    private static func deleteSingleItemFromKeychain(_ account: String) {
        UserDefaults.standard.removeObject(forKey: legacyPrefix + account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    @discardableResult
    private static func migrateUserDefaultsOnlyLocked() -> Bool {
        var changed = false
        let allDefaults = UserDefaults.standard.dictionaryRepresentation()
        for (k, v) in allDefaults where k.hasPrefix(legacyPrefix) {
            let key = String(k.dropFirst(legacyPrefix.count))
            if let strVal = v as? String, !strVal.isEmpty {
                if memoryCache[key] == nil {
                    memoryCache[key] = strVal
                    changed = true
                }
            }
            UserDefaults.standard.removeObject(forKey: k)
        }
        return changed
    }

    /// Для обратной совместимости вызовов.
    static func migrateAllIfNeeded() {
        preloadAllIfNeeded()
    }
}
