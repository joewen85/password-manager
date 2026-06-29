import Foundation
import LocalAuthentication
import Security

struct MacBiometricCredentialStore: Sendable {
    static let keychainService = "life.devops.passwordmanager.macos.biometric-unlock.v2"
    static let legacyKeychainServices = [
        "com.example.password-manager.native.macos.biometric-unlock.v2",
        "com.example.password-manager.native.macos.biometric-unlock"
    ]

    private let service = Self.keychainService
    private let legacyServices = Self.legacyKeychainServices
    private let account = "master-password"

    func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func hasSavedCredential() -> Bool {
        credentialQueries.contains { query in
            var query = query
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return status == errSecSuccess
        }
    }

    func savePassword(_ password: String, reason: String) async throws {
        try await authenticate(reason: reason)
        guard let data = password.data(using: .utf8) else {
            throw MacBiometricCredentialStoreError.invalidCredentialData
        }

        clear()

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw MacBiometricCredentialStoreError.keychainStatus(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw MacBiometricCredentialStoreError.keychainStatus(status)
        }
    }

    func readPassword(reason: String) async throws -> String {
        try await authenticate(reason: reason)
        var lastStatus = errSecItemNotFound
        for baseQuery in credentialQueries {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                lastStatus = status
                continue
            }
            guard status == errSecSuccess else {
                throw MacBiometricCredentialStoreError.keychainStatus(status)
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw MacBiometricCredentialStoreError.invalidCredentialData
            }
            return password
        }
        throw lastStatus == errSecItemNotFound
            ? MacBiometricCredentialStoreError.missingCredential
            : MacBiometricCredentialStoreError.keychainStatus(lastStatus)
    }

    func clear() {
        credentialQueries.forEach { _ = SecItemDelete($0 as CFDictionary) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private var credentialQueries: [[String: Any]] {
        [baseQuery] + legacyServices.map {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: $0,
                kSecAttrAccount as String: account
            ]
        }
    }

    private func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw MacBiometricCredentialStoreError.unavailable(error?.localizedDescription)
        }

        let authenticated = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard authenticated else {
            throw MacBiometricCredentialStoreError.authenticationFailed
        }
    }
}

enum MacBiometricCredentialStoreError: LocalizedError {
    case unavailable(String?)
    case authenticationFailed
    case missingCredential
    case invalidCredentialData
    case keychainAccessControlFailed(String?)
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message ?? "Touch ID unlock is not available on this Mac."
        case .authenticationFailed:
            "Touch ID authentication failed."
        case .missingCredential:
            "Touch ID unlock has not been enabled."
        case .invalidCredentialData:
            "Stored Touch ID credential is invalid."
        case .keychainAccessControlFailed(let message):
            message ?? "Could not create Touch ID Keychain access control."
        case .keychainStatus(let status):
            (
                SecCopyErrorMessageString(status, nil) as String? ??
                    "Keychain operation failed with status \(status)."
            ) + " (\(status))"
        }
    }
}
