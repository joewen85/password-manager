import Testing
@testable import PasswordManageriOSCore

@Suite("iOSBiometricCredentialStore")
struct iOSBiometricCredentialStoreTests {
    @Test("Keychain service uses production bundle namespace")
    func keychainServiceUsesProductionBundleNamespace() {
        #expect(iOSBiometricCredentialStore.keychainService == "life.devops.passwordmanager.biometric-unlock")
        #expect(!iOSBiometricCredentialStore.keychainService.contains("example"))
    }
}
