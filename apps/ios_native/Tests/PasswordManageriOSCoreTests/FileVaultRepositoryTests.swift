import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("FileVaultRepository")
struct FileVaultRepositoryTests {
    @Test("Encrypted envelope persists without plaintext snapshot fields")
    func encryptedEnvelopePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSCoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let crypto = VaultCryptoService()
        let password = "test-password"
        let salt = Data((0..<16).map(UInt8.init))
        let metadataSalt = Data((16..<32).map(UInt8.init))
        let nonce = Data((32..<44).map(UInt8.init))
        let record = try crypto.makeMasterKeyRecord(
            password: password,
            salt: salt,
            metadataSalt: metadataSalt
        )
        let key = try crypto.verify(password: password, record: record)
        let snapshot = VaultSnapshot(
            entries: [
                VaultEntry(
                    label: "Production Email",
                    type: .credential,
                    payload: .credential(
                        CredentialPayload(
                            username: "admin@example.com",
                            password: "secret-password",
                            token: "totp-token",
                            appId: "mail",
                            accessKey: "access-key",
                            secretKey: "secret-key",
                            notes: "private note",
                            tags: ["work"],
                            category: "Default"
                        )
                    )
                )
            ],
            categories: ["Default"],
            tags: ["work"],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encrypted = try crypto.encrypt(
            repository.encodeSnapshot(snapshot),
            key: key,
            nonceBytes: nonce
        )
        let envelope = VaultPersistenceEnvelope(
            masterKeyRecord: record,
            encryptedVault: encrypted,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try repository.saveEnvelope(envelope)

        let rawFile = try String(contentsOf: repository.vaultURL, encoding: .utf8)
        #expect(rawFile.contains("encryptedVault"))
        #expect(rawFile.contains("masterKeyRecord"))
        #expect(!rawFile.contains("Production Email"))
        #expect(!rawFile.contains("admin@example.com"))
        #expect(!rawFile.contains("secret-password"))
        #expect(!rawFile.contains("secret-key"))

        let optionalEnvelope = try repository.loadEnvelope()
        let loadedEnvelope = try #require(optionalEnvelope)
        let loadedEncrypted = try #require(loadedEnvelope.encryptedVault)
        let decrypted = try crypto.decrypt(loadedEncrypted, key: key)
        let decoded = try repository.decodeSnapshot(decrypted)

        #expect(decoded.entries.count == 1)
        #expect(decoded.entries.first?.label == "Production Email")
        #expect(decoded.entries.first?.payload.category == "Default")
        #expect(decoded.tags == ["work"])
    }

    @Test("Backup copies the encrypted vault envelope")
    func backupCopiesEncryptedEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let envelope = VaultPersistenceEnvelope(
            schemaVersion: 1,
            masterKeyRecord: MasterKeyRecord(
                saltBase64: "salt",
                iterations: 600_000,
                verifierBase64: "verifier"
            ),
            encryptedVault: EncryptedPayloadRecord(
                ciphertext: "ciphertext",
                nonce: "nonce",
                mac: "mac",
                version: 1
            ),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try repository.saveEnvelope(envelope)

        let backupURL = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_001))

        #expect(backupURL.lastPathComponent == "vault-20231114-221321.json")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try String(contentsOf: backupURL) == String(contentsOf: repository.vaultURL))
    }

    @Test("Backup retention keeps newest five backups")
    func backupRetentionKeepsNewestFiveBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSBackupRetentionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let envelope = VaultPersistenceEnvelope(
            schemaVersion: 1,
            masterKeyRecord: MasterKeyRecord(
                saltBase64: "salt",
                iterations: 600_000,
                verifierBase64: "verifier"
            ),
            encryptedVault: EncryptedPayloadRecord(
                ciphertext: "ciphertext",
                nonce: "nonce",
                mac: "mac",
                version: 1
            ),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try repository.saveEnvelope(envelope)

        for offset in 1...7 {
            _ = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(offset)))
        }

        let backupNames = try repository.listBackups().map(\.lastPathComponent)

        #expect(backupNames.count == FileVaultRepository.backupRetentionCount)
        #expect(backupNames == [
            "vault-20231114-221327.json",
            "vault-20231114-221326.json",
            "vault-20231114-221325.json",
            "vault-20231114-221324.json",
            "vault-20231114-221323.json"
        ])
    }

    @Test("Restore latest backup replaces current vault envelope")
    func restoreLatestBackupReplacesCurrentVaultEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSRestoreBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        func envelope(ciphertext: String) -> VaultPersistenceEnvelope {
            VaultPersistenceEnvelope(
                schemaVersion: 1,
                masterKeyRecord: MasterKeyRecord(
                    saltBase64: "salt",
                    iterations: 600_000,
                    verifierBase64: "verifier"
                ),
                encryptedVault: EncryptedPayloadRecord(
                    ciphertext: ciphertext,
                    nonce: "nonce",
                    mac: "mac",
                    version: 1
                ),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        try repository.saveEnvelope(envelope(ciphertext: "oldest"))
        _ = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_001))
        try repository.saveEnvelope(envelope(ciphertext: "newest"))
        let newestBackupURL = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_002))
        try repository.saveEnvelope(envelope(ciphertext: "current"))

        let restoredURL = try repository.restoreLatestBackup()

        #expect(restoredURL.lastPathComponent == newestBackupURL.lastPathComponent)
        #expect(try String(contentsOf: newestBackupURL) == String(contentsOf: repository.vaultURL))
        #expect(try repository.loadEnvelope()?.encryptedVault?.ciphertext == "newest")
    }

    @Test("Snapshot export and import round trip through local directories")
    func snapshotExportImportRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSImportExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let snapshot = VaultSnapshot(
            entries: [
                VaultEntry(
                    label: "Imported Email",
                    type: .credential,
                    payload: .credential(
                        CredentialPayload(
                            username: "import@example.com",
                            password: "secret",
                            tags: ["import"],
                            category: "Imports"
                        )
                    )
                )
            ],
            categories: ["Imports"],
            tags: ["import"],
            security: SecuritySettings(requireTotp: true, totpSecret: "JBSWY3DPEHPK3PXP"),
            syncStatus: "Idle",
            lastBackupStatus: "No backup has run",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let exportURL = try repository.saveSnapshotExport(
            snapshot,
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let importURL = try repository.importsDirectoryURL.appendingPathComponent(exportURL.lastPathComponent)
        try FileManager.default.copyItem(at: exportURL, to: importURL)

        let imported = try repository.loadSnapshotImport(named: exportURL.lastPathComponent)

        #expect(exportURL.lastPathComponent == "vault-export-20231114-221321.json")
        #expect(imported.entries.count == 1)
        #expect(imported.entries.first?.label == "Imported Email")
        #expect(imported.security.requireTotp)
        #expect(imported.security.totpSecret == "JBSWY3DPEHPK3PXP")
    }

    @Test("Entry and category scoped exports decode from imports")
    func scopedExportsDecodeFromImports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSScopedExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let entry = VaultEntry(
            label: "Scoped Email",
            type: .credential,
            payload: .credential(
                CredentialPayload(
                    username: "scoped@example.com",
                    password: "secret",
                    category: "Scoped"
                )
            )
        )

        let entryExportURL = try repository.saveEntryExport(entry, at: Date(timeIntervalSince1970: 1_700_000_001))
        let categoryExportURL = try repository.saveCategoryExport(
            category: "Scoped",
            entries: [entry],
            at: Date(timeIntervalSince1970: 1_700_000_002)
        )
        try FileManager.default.copyItem(
            at: entryExportURL,
            to: repository.importsDirectoryURL.appendingPathComponent(entryExportURL.lastPathComponent)
        )
        try FileManager.default.copyItem(
            at: categoryExportURL,
            to: repository.importsDirectoryURL.appendingPathComponent(categoryExportURL.lastPathComponent)
        )

        let entryImport = try repository.loadScopedImport(named: entryExportURL.lastPathComponent)
        let categoryImport = try repository.loadScopedImport(named: categoryExportURL.lastPathComponent)

        #expect(entryImport.scope == .item)
        #expect(entryImport.item?.label == "Scoped Email")
        #expect(categoryImport.scope == .category)
        #expect(categoryImport.category == "Scoped")
        #expect(categoryImport.items?.count == 1)
    }

    @Test("Entry export can keep only selected fields")
    func entryExportCanKeepOnlySelectedFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSSelectedEntryExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let customFieldID = UUID()
        let entry = VaultEntry(
            label: "Scoped Email",
            type: .credential,
            payload: .credential(
                CredentialPayload(
                    username: "scoped@example.com",
                    password: "secret",
                    token: "token",
                    tags: ["selected", "private"],
                    category: "Scoped"
                )
            ),
            customFields: [
                CustomField(id: customFieldID, name: "Recovery", value: "code"),
                CustomField(name: "Private note", value: "hidden")
            ]
        )

        let exportURL = try repository.saveEntryExport(
            entry,
            selectedFieldIDs: ["label", "credential.username", "custom.\(customFieldID.uuidString)"],
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ScopedVaultExport.self, from: Data(contentsOf: exportURL))
        let exportedEntry = try #require(export.item)
        guard case .credential(let credential) = exportedEntry.payload else {
            Issue.record("Expected credential payload")
            return
        }

        #expect(exportedEntry.label == "Scoped Email")
        #expect(credential.username == "scoped@example.com")
        #expect(credential.password.isEmpty)
        #expect(credential.token.isEmpty)
        #expect(credential.tags.isEmpty)
        #expect(credential.category.isEmpty)
        #expect(exportedEntry.customFields == [CustomField(id: customFieldID, name: "Recovery", value: "code")])
    }
}
