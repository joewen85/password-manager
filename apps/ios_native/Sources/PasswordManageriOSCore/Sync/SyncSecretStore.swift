import Foundation
import Security

protocol SyncSecretStore {
    func load(deviceId: String) throws -> SyncSecretBundle
    func save(_ secrets: SyncSecretBundle, deviceId: String) throws
    func delete(deviceId: String) throws
}

enum SyncSecretStoreError: LocalizedError, Equatable {
    case encodeFailed
    case decodeFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            "Sync secrets could not be encoded."
        case .decodeFailed:
            "Sync secrets could not be decoded."
        case .keychain(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

struct KeychainSyncSecretStore: SyncSecretStore {
    var service = "PasswordManagerNative.syncSecrets"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load(deviceId: String) throws -> SyncSecretBundle {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .empty
        }
        guard status == errSecSuccess else {
            throw SyncSecretStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let decoded = try? decoder.decode(SyncSecretBundle.self, from: data) else {
            throw SyncSecretStoreError.decodeFailed
        }
        return decoded
    }

    func save(_ secrets: SyncSecretBundle, deviceId: String) throws {
        if secrets.isEmpty {
            try delete(deviceId: deviceId)
            return
        }
        guard let data = try? encoder.encode(secrets) else {
            throw SyncSecretStoreError.encodeFailed
        }

        let query = baseQuery(deviceId: deviceId)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SyncSecretStoreError.keychain(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SyncSecretStoreError.keychain(addStatus)
        }
    }

    func delete(deviceId: String) throws {
        let status = SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncSecretStoreError.keychain(status)
        }
    }

    private func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId
        ]
    }
}

final class InMemorySyncSecretStore: SyncSecretStore {
    private var storage: [String: SyncSecretBundle] = [:]

    func load(deviceId: String) throws -> SyncSecretBundle {
        storage[deviceId] ?? .empty
    }

    func save(_ secrets: SyncSecretBundle, deviceId: String) throws {
        if secrets.isEmpty {
            storage.removeValue(forKey: deviceId)
        } else {
            storage[deviceId] = secrets
        }
    }

    func delete(deviceId: String) throws {
        storage.removeValue(forKey: deviceId)
    }
}
