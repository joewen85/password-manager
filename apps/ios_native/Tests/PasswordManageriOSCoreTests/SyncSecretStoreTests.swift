import Testing
@testable import PasswordManageriOSCore

@Suite("SyncSecretStore")
struct SyncSecretStoreTests {
    @Test("Settings can be redacted and restored with secrets")
    func settingsRedactionAndRestore() {
        var settings = SyncSettings.defaults(deviceId: "device-1")
        settings.webdavPassword = "webdav-password"
        settings.presignedDownloadUrl = "https://download.example.com/vault"
        settings.presignedUploadUrl = "https://upload.example.com/vault"

        let secrets = settings.syncSecrets
        let redacted = settings.redactedForPlaintextStorage()
        let restored = redacted.applyingSecrets(secrets)

        #expect(secrets.webdavPassword == "webdav-password")
        #expect(secrets.presignedDownloadUrl == "https://download.example.com/vault")
        #expect(secrets.presignedUploadUrl == "https://upload.example.com/vault")
        #expect(redacted.webdavPassword.isEmpty)
        #expect(redacted.presignedDownloadUrl.isEmpty)
        #expect(redacted.presignedUploadUrl.isEmpty)
        #expect(restored.webdavPassword == settings.webdavPassword)
        #expect(restored.presignedDownloadUrl == settings.presignedDownloadUrl)
        #expect(restored.presignedUploadUrl == settings.presignedUploadUrl)
    }

    @Test("In-memory secret store replaces and deletes secrets")
    func inMemorySecretStoreLifecycle() throws {
        let store = InMemorySyncSecretStore()
        let deviceId = "device-1"
        let secrets = SyncSecretBundle(
            webdavPassword: "webdav-password",
            presignedDownloadUrl: "https://download.example.com/vault",
            presignedUploadUrl: "https://upload.example.com/vault"
        )

        #expect(try store.load(deviceId: deviceId) == .empty)
        try store.save(secrets, deviceId: deviceId)
        #expect(try store.load(deviceId: deviceId) == secrets)
        try store.save(.empty, deviceId: deviceId)
        #expect(try store.load(deviceId: deviceId) == .empty)
        try store.save(secrets, deviceId: deviceId)
        try store.delete(deviceId: deviceId)
        #expect(try store.load(deviceId: deviceId) == .empty)
    }
}
