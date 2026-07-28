import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("FileVaultRepository")
struct FileVaultRepositoryTests {
    @Test("Encrypted envelope persists without plaintext snapshot fields")
    func encryptedEnvelopePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test("Snapshot decoding accepts Android backupStatus key")
    func snapshotDecodingAcceptsAndroidBackupStatusKey() throws {
        let repository = FileVaultRepository(baseDirectory: FileManager.default.temporaryDirectory)
        let data = Data(
            """
            {
              "entries": [],
              "categories": ["Android"],
              "tags": ["mobile"],
              "security": {
                "requireTotp": false,
                "totpSecret": ""
              },
              "syncStatus": "Android sync idle",
              "backupStatus": "Backup saved: vault-20260526-153000.json",
              "updatedAt": "2026-05-26T15:30:00Z"
            }
            """.utf8
        )

        let snapshot = try repository.decodeSnapshot(data)

        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.categories == ["Android"])
        #expect(snapshot.tags == ["mobile"])
        #expect(snapshot.syncStatus == "Android sync idle")
        #expect(snapshot.lastBackupStatus == "Backup saved: vault-20260526-153000.json")
    }

    @Test("Snapshot decoding defaults missing custom fields")
    func snapshotDecodingDefaultsMissingCustomFields() throws {
        let repository = FileVaultRepository(baseDirectory: FileManager.default.temporaryDirectory)
        let data = Data(
            """
            {
              "entries": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "label": "Legacy Entry",
                  "type": "credential",
                  "payload": {
                    "credential": {
                      "username": "legacy@example.com",
                      "password": "secret",
                      "accounts": [
                        {
                          "username": "secondary",
                          "password": "secondary-secret",
                          "note": "backup"
                        }
                      ],
                      "token": "",
                      "appId": "",
                      "accessKey": "",
                      "secretKey": "",
                      "notes": "",
                      "tags": [],
                      "category": "Legacy"
                    }
                  },
                  "createdAt": "2026-05-26T15:30:00Z",
                  "updatedAt": "2026-05-26T15:30:00Z"
                }
              ],
              "categories": ["Legacy"],
              "categoryTemplates": [
                {
                  "category": "Legacy",
                  "fields": [
                    {
                      "id": "template-name",
                      "name": "名称"
                    },
                    {
                      "id": "template-note",
                      "name": "备注"
                    }
                  ]
                }
              ],
              "tags": [],
              "updatedAt": "2026-05-26T15:30:00Z"
            }
            """.utf8
        )

        let snapshot = try repository.decodeSnapshot(data)

        #expect(snapshot.entries.first?.label == "Legacy Entry")
        #expect(snapshot.entries.first?.customFields == [])
        if case .credential(let credential) = snapshot.entries.first?.payload {
            #expect(credential.accounts.first?.username == "secondary")
            #expect(credential.accounts.first?.password == "secondary-secret")
        } else {
            Issue.record("Expected credential payload")
        }
        #expect(snapshot.categoryTemplates.first?.category == "Legacy")
        #expect(snapshot.categoryTemplates.first?.fields.map(\.name) == ["名称", "备注"])
    }

    @Test("Snapshot decoding defaults category templates for legacy snapshots")
    func snapshotDecodingDefaultsCategoryTemplatesForLegacySnapshots() throws {
        let repository = FileVaultRepository(baseDirectory: FileManager.default.temporaryDirectory)
        let data = Data(
            """
            {
              "entries": [],
              "categories": ["Legacy"],
              "tags": [],
              "updatedAt": "2026-05-26T15:30:00Z"
            }
            """.utf8
        )

        let snapshot = try repository.decodeSnapshot(data)

        #expect(snapshot.categoryTemplates == [
            CategoryTemplate(category: "Legacy")
        ])
        #expect(snapshot.categoryTemplates.first?.fields.map(\.name) == ["名称", "备注"])
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
        #expect(
            try String(contentsOf: backupURL, encoding: .utf8)
                == String(contentsOf: repository.vaultURL, encoding: .utf8)
        )
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
        #expect(
            try String(contentsOf: newestBackupURL, encoding: .utf8)
                == String(contentsOf: repository.vaultURL, encoding: .utf8)
        )
        #expect(try repository.loadEnvelope()?.encryptedVault?.ciphertext == "newest")
    }

    @Test("Restore named backup validates and restores the selected file")
    func restoreNamedBackupValidatesAndRestoresSelectedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSRestoreNamedBackupTests-\(UUID().uuidString)", isDirectory: true)
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

        try repository.saveEnvelope(envelope(ciphertext: "first"))
        let firstBackupURL = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_001))
        try repository.saveEnvelope(envelope(ciphertext: "second"))
        _ = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_002))
        try repository.saveEnvelope(envelope(ciphertext: "current"))

        let restoredURL = try repository.restoreBackup(named: "../\(firstBackupURL.lastPathComponent)")

        #expect(restoredURL.lastPathComponent == firstBackupURL.lastPathComponent)
        #expect(try repository.loadEnvelope()?.encryptedVault?.ciphertext == "first")
        #expect(throws: FileVaultRepositoryError.backupMissing) {
            try repository.restoreBackup(named: "vault-not-a-backup.json")
        }
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

    @Test("Export data helpers produce document-ready JSON")
    func exportDataHelpersProduceDocumentReadyJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSDocumentExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let customFieldID = "22222222-2222-2222-2222-222222222222"
        let omittedCustomFieldID = "33333333-3333-3333-3333-333333333333"
        let entry = VaultEntry(
            label: "Document Export",
            type: .credential,
            payload: .credential(
                CredentialPayload(
                    username: "document@example.com",
                    password: "secret",
                    tags: ["finance"],
                    category: "Documents"
                )
            ),
            customFields: [
                CustomField(id: customFieldID, name: "Recovery Email", value: "recovery@example.com"),
                CustomField(id: omittedCustomFieldID, name: "Internal Note", value: "omit me")
            ]
        )
        let snapshot = VaultSnapshot(
            entries: [entry],
            categories: ["Documents"],
            tags: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let snapshotExport = try repository.makeSnapshotExport(
            snapshot,
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let entryExport = try repository.makeEntryExport(
            entry,
            at: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let categoryExport = try repository.makeCategoryExport(
            category: "Documents",
            entries: [entry],
            at: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let selectedEntryExport = try repository.makeEntryExport(
            entry,
            selectedFieldIDs: [
                "label",
                "category",
                "credential.username",
                "custom.\(customFieldID)"
            ],
            at: Date(timeIntervalSince1970: 1_700_000_004)
        )

        #expect(snapshotExport.fileName == "vault-export-20231114-221321.json")
        #expect(entryExport.fileName == "entry-export-Document_Export-20231114-221322.json")
        #expect(categoryExport.fileName == "category-export-Documents-20231114-221323.json")
        #expect(try repository.decodeSnapshot(snapshotExport.data).entries.first?.label == "Document Export")
        #expect(try repository.decodeScopedExport(entryExport.data).item?.label == "Document Export")
        #expect(try repository.decodeScopedExport(categoryExport.data).items?.count == 1)

        let selectedEntry = try #require(repository.decodeScopedExport(selectedEntryExport.data).item)
        #expect(selectedEntry.label == "Document Export")
        #expect(selectedEntry.payload.category == "Documents")
        #expect(selectedEntry.payload.tags == [])
        #expect(selectedEntry.customFields == [
            CustomField(id: customFieldID, name: "Recovery Email", value: "recovery@example.com")
        ])
        if case .credential(let payload) = selectedEntry.payload {
            #expect(payload.username == "document@example.com")
            #expect(payload.password == "")
        } else {
            Issue.record("Selected export should keep the credential payload type.")
        }
    }
}
