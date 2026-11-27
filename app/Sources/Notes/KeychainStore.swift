import Foundation
import Security

/// Archiviazione della chiave API nel Portachiavi (mai in UserDefaults in chiaro).
enum KeychainStore {
    private static let service = "com.werootbox.recap"

    /// Servizio usato quando l'app si chiamava CallT.
    private static let legacyService = LegacyMigration.legacyBundleID

    static func read(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        // Chiave salvata da CallT: la copia sotto il nuovo nome e la usa.
        guard let legacy = read(account, service: legacyService) else { return nil }
        write(legacy, account: account)
        return legacy
    }

    private static func read(_ account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        if value.isEmpty {
            delete(account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
