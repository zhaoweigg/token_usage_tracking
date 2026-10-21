import Foundation
import Security

// The app and its widget already share this signed App Group. Its Keychain
// access group keeps credentials encrypted and outside shared snapshot files.
enum SharedCredentialStore {
    private static func query(service: String, id: UUID, group: String? = WidgetSnapshotStore.groupID) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    static func load(service: String, id: UUID) throws -> Data? {
        var query = query(service: service, id: id)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }
        guard status == errSecItemNotFound else { throw ClaudeAuthorizationError.secureStorage }
        #if HEADROOM_APP
        // Existing installations stored these in the app's private access group.
        // Copy successfully before deleting the explicitly identified old item.
        if let legacy = try legacy(service: service, id: id), let data = legacy[kSecValueData as String] as? Data {
            try save(data, service: service, id: id)
            return data
        }
        #endif
        return nil
    }

    static func save(_ data: Data, service: String, id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let query = query(service: service, id: id)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw ClaudeAuthorizationError.secureStorage }
        } else if status != errSecSuccess { throw ClaudeAuthorizationError.secureStorage }
        #if HEADROOM_APP
        removeLegacy(service: service, id: id)
        #endif
    }

    static func remove(service: String, id: UUID) {
        SecItemDelete(query(service: service, id: id) as CFDictionary)
        #if HEADROOM_APP
        removeLegacy(service: service, id: id)
        #endif
    }

    #if HEADROOM_APP
    private static func legacy(service: String, id: UUID) throws -> [String: Any]? {
        var query = query(service: service, id: id, group: nil)
        query[kSecReturnAttributes as String] = true; query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClaudeAuthorizationError.secureStorage }
        return (items as? [[String: Any]])?.first { ($0[kSecAttrAccessGroup as String] as? String) != WidgetSnapshotStore.groupID }
    }
    private static func removeLegacy(service: String, id: UUID) {
        guard let item = try? legacy(service: service, id: id),
              let group = item[kSecAttrAccessGroup as String] as? String, group != WidgetSnapshotStore.groupID else { return }
        SecItemDelete(query(service: service, id: id, group: group) as CFDictionary)
    }
    #endif
}
