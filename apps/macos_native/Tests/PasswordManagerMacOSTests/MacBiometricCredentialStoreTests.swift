import Testing
@testable import PasswordManagerMacOSApp

@Suite("MacBiometricCredentialStore")
struct MacBiometricCredentialStoreTests {
    @Test("Keychain service uses production bundle namespace")
    func keychainServiceUsesProductionBundleNamespace() {
        #expect(MacBiometricCredentialStore.keychainService == "life.devops.passwordmanager.macos.biometric-unlock.v2")
        #expect(!MacBiometricCredentialStore.keychainService.contains("example"))
    }

    @Test("Legacy Keychain services remain available for migration cleanup")
    func legacyKeychainServicesRemainAvailableForMigrationCleanup() {
        #expect(MacBiometricCredentialStore.legacyKeychainServices == [
            "com.example.password-manager.native.macos.biometric-unlock.v2",
            "com.example.password-manager.native.macos.biometric-unlock"
        ])
    }
}
