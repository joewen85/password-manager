import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("VaultStore Data Management")
struct VaultStoreDataManagementTests {
    @MainActor
    @Test("Deleting entry records tombstone timestamp and editing clears it")
    func deletingEntryRecordsTombstoneTimestampAndEditingClearsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSTombstoneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        var draft = EntryDraft()
        draft.label = "Production Login"
        draft.category = "Work"
        draft.tags = ["ops"]
        store.upsert(draft, editing: nil)

        let created = try #require(store.entries.first)
        #expect(created.deletedAt == nil)

        store.delete(created)
        store.lock()
        #expect(store.unlock(password: "test-password"))

        let deleted = try #require(store.entries.first { $0.id == created.id })
        #expect(deleted.isDeleted)
        #expect(deleted.deletedAt == deleted.updatedAt)
        #expect(store.filteredEntries(searchText: "", filter: .all).isEmpty)

        var restoreDraft = EntryDraft(entry: deleted)
        restoreDraft.label = "Restored Login"
        store.upsert(restoreDraft, editing: deleted)
        store.lock()
        #expect(store.unlock(password: "test-password"))

        let restored = try #require(store.entries.first { $0.id == created.id })
        #expect(!restored.isDeleted)
        #expect(restored.deletedAt == nil)
        #expect(restored.label == "Restored Login")
        #expect(store.filteredEntries(searchText: "", filter: .all).map(\.id) == [created.id])
    }

    @MainActor
    @Test("Clear data requires master password and resets vault content")
    func clearDataRequiresMasterPasswordAndResetsVaultContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSClearDataTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        var draft = EntryDraft()
        draft.label = "Production Login"
        draft.category = "Work"
        draft.tags = ["ops"]
        store.upsert(draft, editing: nil)
        #expect(store.addCategory("Personal"))
        #expect(store.addTag("prod"))
        store.setRequireTotp(true)
        store.setTotpSecret("JBSWY3DPEHPK3PXP")
        store.runBackup()

        #expect(!store.clearAllData(password: "wrong-password"))
        #expect(store.entries.count == 1)
        #expect(store.categories == ["Personal", "Work"])
        #expect(store.tags == ["ops", "prod"])
        #expect(store.requireTotp)
        #expect(store.totpSecret == "JBSWY3DPEHPK3PXP")
        #expect(store.statusMessage == "Vault authentication failed.")

        #expect(store.clearAllData(password: "test-password"))
        #expect(store.entries.isEmpty)
        #expect(store.categories.isEmpty)
        #expect(store.tags.isEmpty)
        #expect(!store.requireTotp)
        #expect(store.totpSecret.isEmpty)
        #expect(store.lastBackupStatus == "No backup has run")
        #expect(store.statusMessage == "Vault data cleared.")

        store.lock()
        #expect(store.unlock(password: "test-password"))
        #expect(store.entries.isEmpty)
        #expect(store.categories.isEmpty)
        #expect(store.tags.isEmpty)
        #expect(!store.requireTotp)
        #expect(store.totpSecret.isEmpty)
        #expect(store.lastBackupStatus == "No backup has run")
        #expect(try repository.decodeSnapshot(
            try VaultCryptoService().decrypt(
                try #require(repository.loadEnvelope()?.encryptedVault),
                key: try VaultCryptoService().verify(
                    password: "test-password",
                    record: try #require(repository.loadEnvelope()?.masterKeyRecord)
                )
            )
        ).entries.isEmpty)
    }
}
