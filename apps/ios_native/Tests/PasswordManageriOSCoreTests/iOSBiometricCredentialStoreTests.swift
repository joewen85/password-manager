import Testing
@testable import PasswordManageriOSCore

@Suite("iOSBiometricCredentialStore")
struct iOSBiometricCredentialStoreTests {
    @Test("Keychain service uses production bundle namespace")
    func keychainServiceUsesProductionBundleNamespace() {
        #expect(iOSBiometricCredentialStore.keychainService == "life.dev-ops.passwordmanager.biometric-unlock")
        #expect(!iOSBiometricCredentialStore.keychainService.contains("example"))
    }
}
