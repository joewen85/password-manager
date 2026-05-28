import Foundation
import LocalAuthentication
import Security

struct iOSBiometricCredentialStore: Sendable {
    private let service = "com.example.password-manager.native.ios.biometric-unlock"
    private let account = "master-password"

    func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func hasSavedCredential() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func savePassword(_ password: String, reason: String) async throws {
        let context = try await authenticatedContext(reason: reason)
        clear()

        guard let data = password.data(using: .utf8) else {
            throw iOSBiometricCredentialStoreError.invalidCredentialData
        }

        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessControlError
        ) else {
            throw iOSBiometricCredentialStoreError.keychainAccessControlFailed(
                accessControlError?.takeRetainedValue().localizedDescription
            )
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecUseAuthenticationContext as String] = context

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw iOSBiometricCredentialStoreError.keychainStatus(status)
        }
    }

    func readPassword(reason: String) async throws -> String {
        let context = try await authenticatedContext(reason: reason)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? iOSBiometricCredentialStoreError.missingCredential
                : iOSBiometricCredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw iOSBiometricCredentialStoreError.invalidCredentialData
        }
        return password
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func authenticatedContext(reason: String) async throws -> LAContext {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw iOSBiometricCredentialStoreError.unavailable(error?.localizedDescription)
        }

        let authenticated = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard authenticated else {
            throw iOSBiometricCredentialStoreError.authenticationFailed
        }
        return context
    }
}

enum iOSBiometricCredentialStoreError: LocalizedError {
    case unavailable(String?)
    case authenticationFailed
    case missingCredential
    case invalidCredentialData
    case keychainAccessControlFailed(String?)
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message ?? "Biometric unlock is not available on this device."
        case .authenticationFailed:
            "Biometric authentication failed."
        case .missingCredential:
            "Biometric unlock has not been enabled."
        case .invalidCredentialData:
            "Stored biometric credential is invalid."
        case .keychainAccessControlFailed(let message):
            message ?? "Could not create biometric Keychain access control."
        case .keychainStatus(let status):
            SecCopyErrorMessageString(status, nil) as String? ??
                "Keychain operation failed with status \(status)."
        }
    }
}
