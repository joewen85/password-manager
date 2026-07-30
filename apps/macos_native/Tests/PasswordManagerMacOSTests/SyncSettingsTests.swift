import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("SyncSettings")
struct SyncSettingsTests {
    @Test("Defaults match Flutter sync settings contract")
    func defaultsMatchFlutterContract() {
        let settings = SyncSettings.defaults(deviceId: "device-1")

        #expect(settings.providerType == .none)
        #expect(settings.webdavPath == "/vault.json")
        #expect(settings.objectStorageObjectKey == "vault.sync.json")
        #expect(!settings.autoSyncEnabled)
        #expect(settings.autoSyncIntervalMinutes == 30)
        #expect(settings.autoSyncIntervalValue == 30)
        #expect(settings.autoSyncIntervalUnit == .minutes)
        #expect(settings.autoSyncOnUnlock)
        #expect(settings.conflictStrategy == .remoteWins)
        #expect(settings.syncMasterKey)
        #expect(settings.deviceId == "device-1")
        #expect(settings.lastSyncRevision == 0)
        #expect(settings.logs.isEmpty)
    }

    @Test("Decoding tolerates missing and unknown values")
    func decodingToleratesMissingAndUnknownValues() throws {
        let data = Data(
            """
            {
              "providerType": "futureProvider",
              "webdavUrl": "https://dav.example.com",
              "ak": "cos-ak",
              "sk": "cos-sk",
              "bucket": "vault-bucket",
              "endpoint": "cos.ap-shanghai.myqcloud.com",
              "appid": "1250000000",
              "customUrl": "https://custom.example.com/root",
              "objectKey": "vaults/device.json",
              "conflictStrategy": "futureStrategy",
              "lastRemoteFingerprint": "etag:remote-v1",
              "logs": [
                {
                  "timestamp": "2026-05-24T03:00:00Z",
                  "message": "done",
                  "level": "info"
                }
              ]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let settings = try decoder.decode(SyncSettings.self, from: data)

        #expect(settings.providerType == .none)
        #expect(settings.webdavUrl == "https://dav.example.com")
        #expect(settings.objectStorageAccessKey == "cos-ak")
        #expect(settings.objectStorageSecretKey == "cos-sk")
        #expect(settings.objectStorageBucket == "vault-bucket")
        #expect(settings.objectStorageEndpoint == "cos.ap-shanghai.myqcloud.com")
        #expect(settings.objectStorageAppId == "1250000000")
        #expect(settings.objectStorageCustomUrl == "https://custom.example.com/root")
        #expect(settings.objectStorageObjectKey == "vaults/device.json")
        #expect(settings.lastRemoteFingerprint == "etag:remote-v1")
        #expect(settings.webdavPath == "/vault.json")
        #expect(settings.conflictStrategy == .remoteWins)
        #expect(settings.syncMasterKey)
        #expect(settings.logs.count == 1)
        #expect(settings.logs.first?.message == "done")
    }

    @Test("Decoding supports second-based sync interval")
    func decodingSupportsSecondBasedSyncInterval() throws {
        let data = Data(
            """
            {
              "autoSyncIntervalValue": 30,
              "autoSyncIntervalUnit": "seconds"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let settings = try decoder.decode(SyncSettings.self, from: data)

        #expect(settings.autoSyncIntervalMinutes == 1)
        #expect(settings.autoSyncIntervalValue == 30)
        #expect(settings.autoSyncIntervalUnit == .seconds)
    }

    @Test("Decoding keeps legacy minute sync interval")
    func decodingKeepsLegacyMinuteSyncInterval() throws {
        let data = Data(
            """
            {
              "autoSyncIntervalMinutes": 15
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let settings = try decoder.decode(SyncSettings.self, from: data)

        #expect(settings.autoSyncIntervalMinutes == 15)
        #expect(settings.autoSyncIntervalValue == 15)
        #expect(settings.autoSyncIntervalUnit == .minutes)
    }

    @Test("Encoding keeps Flutter field names")
    func encodingKeepsFlutterFieldNames() throws {
        var settings = SyncSettings.defaults(deviceId: "device-1")
        settings.autoSyncIntervalMinutes = 1
        settings.autoSyncIntervalValue = 30
        settings.autoSyncIntervalUnit = .seconds
        settings.lastRemoteFingerprint = "etag:remote-v1"
        settings.providerType = .tencentCos
        settings.objectStorageAccessKey = "ak"
        settings.objectStorageSecretKey = "sk"
        settings.objectStorageBucket = "bucket"
        settings.objectStorageEndpoint = "cos.ap-shanghai.myqcloud.com"
        settings.objectStorageAppId = "1250000000"
        settings.objectStorageCustomUrl = "https://custom.example.com"
        settings.objectStorageObjectKey = "vault.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let encoded = try encoder.encode(settings)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let json = try #require(object)

        #expect(json["providerType"] as? String == "tencentCos")
        #expect(json["webdavPath"] as? String == "/vault.json")
        #expect(json["objectStorageAccessKey"] as? String == "ak")
        #expect(json["objectStorageSecretKey"] as? String == "sk")
        #expect(json["objectStorageBucket"] as? String == "bucket")
        #expect(json["objectStorageEndpoint"] as? String == "cos.ap-shanghai.myqcloud.com")
        #expect(json["objectStorageAppId"] as? String == "1250000000")
        #expect(json["objectStorageCustomUrl"] as? String == "https://custom.example.com")
        #expect(json["objectStorageObjectKey"] as? String == "vault.json")
        #expect(json["autoSyncIntervalMinutes"] as? Int == 1)
        #expect(json["autoSyncIntervalValue"] as? Int == 30)
        #expect(json["autoSyncIntervalUnit"] as? String == "seconds")
        #expect(json["lastRemoteFingerprint"] as? String == "etag:remote-v1")
        #expect(json["conflictStrategy"] as? String == "remoteWins")
        #expect(json["syncMasterKey"] as? Bool == true)
    }

    @Test("Factory validates providers and builds configured clients")
    func factoryValidatesProvidersAndBuildsClients() async {
        let transport = SyncSettingsFakeRemoteSyncTransport(
            responses: [
                .success(syncSettingsHTTPResult(
                    url: URL(string: "https://dav.example.com/vault.json")!,
                    statusCode: 200,
                    body: "{}"
                )),
                .success(syncSettingsHTTPResult(
                    url: URL(string: "https://upload.example.com/vault")!,
                    statusCode: 201
                )),
                .success(syncSettingsHTTPResult(
                    url: URL(string: "https://vault-bucket-1250000000.cos.ap-shanghai.myqcloud.com/vault.sync.json")!,
                    statusCode: 200,
                    body: "{}"
                ))
            ]
        )
        let factory = SyncClientFactory()
        var webdav = SyncSettings.defaults(deviceId: "device-1")
        webdav.providerType = .webdav
        webdav.webdavUrl = " https://dav.example.com/root/ "
        webdav.webdavPath = " vault.json "
        webdav.webdavUsername = " alice "
        webdav.webdavPassword = " secret "
        var presigned = SyncSettings.defaults(deviceId: "device-1")
        presigned.providerType = .s3Presigned
        presigned.presignedUploadUrl = "https://upload.example.com/vault"
        var tencent = SyncSettings.defaults(deviceId: "device-1")
        tencent.providerType = .tencentCos
        tencent.objectStorageAccessKey = "cos-ak"
        tencent.objectStorageSecretKey = "cos-sk"
        tencent.objectStorageBucket = "vault-bucket"
        tencent.objectStorageEndpoint = "cos.ap-shanghai.myqcloud.com"
        tencent.objectStorageAppId = "1250000000"

        let missing = factory.makeClient(settings: .defaults(deviceId: "device-1"), transport: transport)
        let webdavClient = factory.makeClient(settings: webdav, transport: transport)
        let presignedClient = factory.makeClient(settings: presigned, transport: transport)
        let tencentClient = factory.makeClient(settings: tencent, transport: transport)

        #expect(missing == nil)
        #expect(webdavClient != nil)
        #expect(presignedClient != nil)
        #expect(tencentClient != nil)
        let webdavResult = await webdavClient?.download()
        let presignedResult = await presignedClient?.upload("{}")
        let tencentResult = await tencentClient?.download()
        #expect(webdavResult == RemoteSyncResult(payload: "{}", statusCode: 200))
        #expect(presignedResult == RemoteSyncResult(payload: nil, statusCode: 201))
        #expect(tencentResult == RemoteSyncResult(payload: "{}", statusCode: 200))
        #expect(transport.requests[0].url?.absoluteString == "https://dav.example.com/root/vault.json")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
        #expect(transport.requests[1].url?.absoluteString == "https://upload.example.com/vault")
        #expect(transport.requests[2].url?.absoluteString == "https://vault-bucket-1250000000.cos.ap-shanghai.myqcloud.com/vault.sync.json")
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization")?.contains("q-ak=cos-ak") == true)
    }

    @Test("Repository stores sync secrets outside plaintext settings file")
    func repositoryStoresSecretsOutsidePlaintextSettingsFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSSyncSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let repository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        var settings = SyncSettings.defaults(deviceId: "device-1")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavUsername = "alice"
        settings.webdavPassword = "webdav-password"
        settings.presignedDownloadUrl = "https://download.example.com/vault"
        settings.presignedUploadUrl = "https://upload.example.com/vault"
        settings.objectStorageAccessKey = "object-ak"
        settings.objectStorageSecretKey = "object-sk"
        settings.objectStorageBucket = "vault-bucket"
        settings.objectStorageEndpoint = "oss-cn-hangzhou.aliyuncs.com"

        try repository.save(settings)

        let optionalRawFile = try repository.rawSettingsFile()
        let rawFile = try #require(optionalRawFile)
        #expect(rawFile.contains("\"providerType\" : \"webdav\""))
        #expect(rawFile.contains("\"webdavUsername\" : \"alice\""))
        #expect(!rawFile.contains("webdav-password"))
        #expect(!rawFile.contains("https://download.example.com/vault"))
        #expect(!rawFile.contains("https://upload.example.com/vault"))
        #expect(!rawFile.contains("object-ak"))
        #expect(!rawFile.contains("object-sk"))
        #expect(rawFile.contains("vault-bucket"))
        #expect(rawFile.contains("oss-cn-hangzhou.aliyuncs.com"))
        #expect(try secretStore.load(deviceId: "device-1") == settings.syncSecrets)

        let loaded = try repository.load()
        #expect(loaded == settings)

        try repository.delete()
        #expect(try repository.rawSettingsFile() == nil)
        #expect(try secretStore.load(deviceId: "device-1") == .empty)
    }

    @MainActor
    @Test("VaultStore persists and reloads sync settings through repository")
    func vaultStorePersistsAndReloadsSyncSettingsThroughRepository() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: syncRepository
        )
        var settings = SyncSettings.defaults(deviceId: "device-1")
        settings.providerType = .s3Presigned
        settings.presignedDownloadUrl = "https://download.example.com/vault"
        settings.presignedUploadUrl = "https://upload.example.com/vault"

        store.updateSyncSettings(settings)

        #expect(store.syncSettings == settings)
        #expect(store.syncStatus == "Configured: S3 Presigned URL")
        #expect(store.statusMessage == "Sync settings saved.")

        let reloadedStore = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: syncRepository
        )
        #expect(reloadedStore.syncSettings == settings)
        #expect(reloadedStore.syncStatus == "Configured: S3 Presigned URL")
    }

    @MainActor
    @Test("VaultStore adopts repository-normalized sync device id")
    func vaultStoreAdoptsRepositoryNormalizedSyncDeviceId() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncDeviceIdTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: syncRepository
        )
        var settings = SyncSettings.defaults(deviceId: "")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavUsername = "alice"
        settings.webdavPassword = "webdav-password"

        store.updateSyncSettings(settings)

        #expect(!store.syncSettings.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(store.syncSettings.deviceId != settings.deviceId)
        #expect(store.syncSettings.providerType == .webdav)
        #expect(try secretStore.load(deviceId: store.syncSettings.deviceId) == store.syncSettings.syncSecrets)

        let reloadedStore = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: syncRepository
        )
        #expect(reloadedStore.syncSettings == store.syncSettings)
        #expect(reloadedStore.syncStatus == "Configured: WebDAV")
    }

    @MainActor
    @Test("VaultStore lists and restores a selected backup")
    func vaultStoreListsAndRestoresSelectedBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreBackupCenterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        var firstDraft = EntryDraft()
        firstDraft.label = "First Login"
        firstDraft.credential.username = "first@example.com"
        store.upsert(firstDraft, editing: nil)
        _ = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_001))
        let firstBackup = try #require(store.listBackups().first)

        var secondDraft = EntryDraft()
        secondDraft.label = "Second Login"
        secondDraft.credential.username = "second@example.com"
        store.upsert(secondDraft, editing: nil)
        _ = try repository.createBackup(at: Date(timeIntervalSince1970: 1_700_000_002))
        #expect(store.listBackups().count == 2)

        store.restoreBackup(fileName: firstBackup.fileName)

        #expect(store.entries.contains { $0.label == "First Login" })
        #expect(!store.entries.contains { $0.label == "Second Login" })
        #expect(store.lastBackupStatus == "Restored backup: \(firstBackup.fileName)")
    }

    @MainActor
    @Test("VaultStore exports and imports selected JSON files")
    func vaultStoreExportsAndImportsSelectedJSONFiles() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSSelectedExportSourceTests-\(UUID().uuidString)", isDirectory: true)
        let targetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSSelectedExportTargetTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: targetDirectory)
        }

        let sourceStore = VaultStore(
            repository: FileVaultRepository(baseDirectory: sourceDirectory),
            syncSettingsRepository: nil
        )
        #expect(sourceStore.setupMasterPassword("source-password", confirmation: "source-password"))
        var draft = EntryDraft()
        draft.label = "Selected Export Login"
        draft.credential.username = "selected@example.com"
        draft.credential.password = "secret"
        draft.category = "Selected"
        sourceStore.upsert(draft, editing: nil)

        let snapshotExport = try #require(sourceStore.makeSnapshotExport())
        let entry = try #require(sourceStore.entries.first)
        let entryExport = try #require(sourceStore.makeEntryExport(entry))
        let snapshotURL = sourceDirectory.appendingPathComponent(snapshotExport.fileName)
        let entryURL = sourceDirectory.appendingPathComponent(entryExport.fileName)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try snapshotExport.data.write(to: snapshotURL)
        try entryExport.data.write(to: entryURL)

        let targetStore = VaultStore(
            repository: FileVaultRepository(baseDirectory: targetDirectory),
            syncSettingsRepository: nil
        )
        #expect(targetStore.setupMasterPassword("target-password", confirmation: "target-password"))

        targetStore.importSnapshot(from: snapshotURL)

        #expect(targetStore.entries.count == 1)
        #expect(targetStore.entries.first?.label == "Selected Export Login")
        #expect(targetStore.categories == ["Selected"])

        targetStore.importScopedExport(from: entryURL, strategy: .keepCopy)

        #expect(targetStore.entries.count == 2)
        #expect(targetStore.entries.filter { $0.label == "Selected Export Login" }.count == 2)
    }

    @MainActor
    @Test("VaultStore sync now uploads snapshot and persists result")
    func vaultStoreSyncNowUploadsSnapshotAndPersistsResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncNowTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var draft = EntryDraft()
        draft.label = "Sync Login"
        draft.credential.username = "sync@example.com"
        draft.credential.password = "secret"
        draft.credential.accounts = [ServiceAccount(username: "ops", password: "account-secret")]
        draft.credential.token = "sync-token"
        draft.credential.secretKey = "sync-secret-key"
        store.upsert(draft, editing: nil)
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        store.updateSyncSettings(settings)
        let client = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: nil, statusCode: 404)],
            uploadStatusCodes: [201]
        )

        await store.syncNow(client: client)

        #expect(client.uploadedPayloads.count == 1)
        let rawUpload = try #require(client.uploadedPayloads.first)
        #expect(!rawUpload.contains("Sync Login"))
        #expect(!rawUpload.contains("sync@example.com"))
        #expect(!rawUpload.contains("secret"))
        #expect(!rawUpload.contains("account-secret"))
        #expect(!rawUpload.contains("sync-token"))
        #expect(!rawUpload.contains("sync-secret-key"))
        #expect(rawUpload.contains("encryptedVault"))
        #expect(!rawUpload.contains("\"snapshot\""))
        let uploaded = try decodeEncryptedSyncPayload(rawUpload, repository: repository)
        #expect(uploaded.deviceId == "mac-device")
        #expect(uploaded.snapshot.entries.contains { $0.label == "Sync Login" })
        #expect(store.syncSettings.lastSyncStatus == "success")
        #expect(store.syncSettings.lastSyncAt == now)
        #expect(store.syncStatus.contains("Synced 1 items"))

        let reloadedStore = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(reloadedStore.unlock(password: "test-password"))
        #expect(reloadedStore.syncSettings.lastSyncStatus == "success")
        #expect(reloadedStore.syncStatus.contains("Synced 1 items"))
        #expect(reloadedStore.entries.contains { $0.label == "Sync Login" })
    }

    @MainActor
    @Test("VaultStore sync applies encrypted remote snapshot")
    func vaultStoreSyncAppliesEncryptedRemoteSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreEncryptedRemoteSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        store.updateSyncSettings(settings)
        let remoteSnapshot = VaultSnapshot(
            entries: [
                VaultEntry(
                    label: "Remote Login",
                    type: .credential,
                    payload: .credential(CredentialPayload(
                        username: "remote@example.com",
                        password: "remote-secret",
                        token: "remote-token",
                        secretKey: "remote-secret-key"
                    )),
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                    version: ["remote-device": 1],
                    updatedBy: "remote-device"
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let remotePayload = try encodeEncryptedSyncPayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 1,
                snapshot: remoteSnapshot
            ),
            repository: repository
        )
        let client = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        await store.syncNow(client: client)

        #expect(store.entries.contains { $0.label == "Remote Login" })
        #expect(!remotePayload.contains("remote-secret"))
        #expect(remotePayload.contains("encryptedVault"))
    }

    @MainActor
    @Test("VaultStore rewrites legacy plaintext remote when no merge upload is needed")
    func vaultStoreRewritesLegacyPlaintextRemoteWhenNoMergeUploadIsNeeded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreLegacyPlaintextRemoteSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        store.updateSyncSettings(settings)
        await store.syncNow(client: VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: nil, statusCode: 404)],
            uploadStatusCodes: [200]
        ))
        let remoteSnapshot = VaultSnapshot(
            entries: [
                VaultEntry(
                    label: "Legacy Remote Login",
                    type: .credential,
                    payload: .credential(CredentialPayload(
                        username: "legacy@example.com",
                        password: "legacy-secret"
                    )),
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                    version: ["remote-device": 1],
                    updatedBy: "remote-device"
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let legacyRemotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 2,
                snapshot: remoteSnapshot
            )
        )
        let client = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: legacyRemotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        await store.syncNow(client: client)

        #expect(store.entries.contains { $0.label == "Legacy Remote Login" })
        #expect(client.uploadedPayloads.count == 1)
        let migrated = try decodeEncryptedSyncPayload(client.uploadedPayloads.first, repository: repository)
        #expect(migrated.revision == 2)
        #expect(migrated.snapshot.entries.contains { $0.label == "Legacy Remote Login" })
        let rawUpload = try #require(client.uploadedPayloads.first)
        #expect(!rawUpload.contains("legacy-secret"))
        #expect(rawUpload.contains("encryptedVault"))
    }

    @MainActor
    @Test("VaultStore sync preserves newly created empty category")
    func vaultStoreSyncPreservesNewlyCreatedEmptyCategory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncCategoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        settings.conflictStrategy = .keepBoth
        store.updateSyncSettings(settings)
        #expect(store.addCategory("test"))
        let client = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: nil, statusCode: 404)],
            uploadStatusCodes: [201]
        )

        await store.syncNow(client: client)

        #expect(store.categories == ["test"])
        #expect(store.categoryTemplates.map(\.category) == ["test"])
        #expect(store.categoryTemplates.first?.fields.map(\.name) == ["名称", "备注"])
        #expect(store.syncSettings.conflictStrategy == .keepBoth)
        let uploaded = try decodeEncryptedSyncPayload(client.uploadedPayloads.first, repository: repository)
        #expect(uploaded.snapshot.categories == ["test"])
        #expect(uploaded.snapshot.categoryTemplates.map(\.category) == ["test"])

        let reloadedStore = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(reloadedStore.unlock(password: "test-password"))
        #expect(reloadedStore.categories == ["test"])
        #expect(reloadedStore.categoryTemplates.map(\.category) == ["test"])
    }

    @MainActor
    @Test("VaultStore sync keeps local empty category when remote revision advanced")
    func vaultStoreSyncKeepsLocalEmptyCategoryWhenRemoteRevisionAdvanced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncMergeCategoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        settings.conflictStrategy = .keepBoth
        settings.lastSyncRevision = 1
        store.updateSyncSettings(settings)
        #expect(store.addCategory("test"))

        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 2,
                snapshot: VaultSnapshot(
                    entries: [],
                    categories: [],
                    categoryTemplates: [],
                    tags: [],
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
                )
            )
        )
        let client = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        await store.syncNow(client: client)

        #expect(store.categories == ["test"])
        #expect(store.categoryTemplates.map(\.category) == ["test"])
        #expect(store.categoryTemplates.first?.fields.map(\.name) == ["名称", "备注"])
        let uploaded = try decodeEncryptedSyncPayload(client.uploadedPayloads.first, repository: repository)
        #expect(uploaded.revision == 3)
        #expect(uploaded.snapshot.categories == ["test"])
        #expect(uploaded.snapshot.categoryTemplates.map(\.category) == ["test"])

        let reloadedStore = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(reloadedStore.unlock(password: "test-password"))
        #expect(reloadedStore.categories == ["test"])
        #expect(reloadedStore.categoryTemplates.map(\.category) == ["test"])
    }

    @MainActor
    @Test("VaultStore sync preserves a newly added category field")
    func vaultStoreSyncPreservesNewlyAddedCategoryField() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncCategoryFieldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        settings.conflictStrategy = .remoteWins
        store.updateSyncSettings(settings)
        #expect(store.addCategory("test"))

        let baselineClient = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: nil, statusCode: 404)],
            uploadStatusCodes: [200]
        )
        await store.syncNow(client: baselineClient)
        let baselineUpload = try decodeEncryptedSyncPayload(
            baselineClient.uploadedPayloads.first,
            repository: repository
        )

        let existingTemplate = try #require(store.categoryTemplates.first)
        let addedField = FieldTemplate(id: "field-owner", name: "Owner")
        #expect(store.updateCategoryTemplate(
            "test",
            fields: existingTemplate.fields + [addedField]
        ))
        #expect(store.categoryTemplates.first?.fields.contains(addedField) == true)

        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: baselineUpload.revision + 1,
                snapshot: baselineUpload.snapshot
            )
        )
        let client = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        await store.syncNow(client: client)

        let syncedTemplate = try #require(store.categoryTemplates.first)
        #expect(syncedTemplate.fields.contains(addedField))
        let uploaded = try decodeEncryptedSyncPayload(client.uploadedPayloads.first, repository: repository)
        #expect(uploaded.snapshot.categoryTemplates.first?.fields.contains(addedField) == true)

        let staleRemotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "stale-device",
                revision: uploaded.revision + 1,
                snapshot: baselineUpload.snapshot
            )
        )
        let staleClient = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: staleRemotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        await store.syncNow(client: staleClient)

        let convergedTemplate = try #require(store.categoryTemplates.first)
        #expect(convergedTemplate.fields.contains(addedField))
        let convergedUpload = try decodeEncryptedSyncPayload(
            staleClient.uploadedPayloads.first,
            repository: repository
        )
        #expect(convergedUpload.snapshot.categoryTemplates.first?.fields.contains(addedField) == true)
    }

    @MainActor
    @Test("VaultStore sync does not restore locally deleted empty category")
    func vaultStoreSyncDoesNotRestoreLocallyDeletedEmptyCategory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncDeletedCategoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        settings.conflictStrategy = .keepBoth
        settings.lastSyncRevision = 2
        store.updateSyncSettings(settings)
        #expect(store.addCategory("test"))
        #expect(store.deleteCategory("test"))

        let staleRemote = VaultSnapshot(
            entries: [],
            categories: ["test"],
            categoryTemplates: [CategoryTemplate(category: "test")],
            tags: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 3,
                snapshot: staleRemote
            )
        )
        let client = VaultStoreSyncFakeClient(
            downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        await store.syncNow(client: client)

        #expect(store.categories == [])
        #expect(store.categoryTemplates == [])
        let uploaded = try decodeEncryptedSyncPayload(client.uploadedPayloads.first, repository: repository)
        #expect(uploaded.revision == 4)
        #expect(uploaded.snapshot.categories == [])
        #expect(uploaded.snapshot.categoryTemplates == [])

        let reloadedStore = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(reloadedStore.unlock(password: "test-password"))
        #expect(reloadedStore.categories == [])
        #expect(reloadedStore.categoryTemplates == [])
    }

    @MainActor
    @Test("VaultStore category deletion survives later sync and supports explicit recreation")
    func vaultStoreCategoryDeletionSurvivesLaterSyncAndSupportsExplicitRecreation() async throws {
        for strategy in [SyncSettingsConflictStrategy.remoteWins, .keepBoth] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "PasswordManagerMacOSVaultStoreRepeatedDeletedCategoryTests-\(strategy.rawValue)-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = InMemorySyncSecretStore()
            let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let engine = VaultSyncEngine(now: { now })
            let repository = FileVaultRepository(baseDirectory: directory)
            let store = VaultStore(
                repository: repository,
                syncSettingsRepository: syncRepository,
                syncEngine: engine
            )
            #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
            var settings = SyncSettings.defaults(deviceId: "mac-device")
            settings.providerType = .webdav
            settings.webdavUrl = "https://dav.example.com/root"
            settings.webdavPath = "/vault.json"
            settings.conflictStrategy = strategy
            settings.lastSyncRevision = 2
            store.updateSyncSettings(settings)
            #expect(store.addCategory("test"))
            #expect(store.deleteCategory("test"))

            let staleRemote = VaultSnapshot(
                entries: [],
                categories: ["test"],
                categoryTemplates: [CategoryTemplate(category: "test")],
                tags: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
            let firstRemotePayload = try encodeEncryptedSyncPayload(
                VaultSyncPayload(
                    exportedAt: now,
                    deviceId: "remote-device",
                    revision: 3,
                    snapshot: staleRemote
                ),
                repository: repository
            )
            let laterRemotePayload = try encodeEncryptedSyncPayload(
                VaultSyncPayload(
                    exportedAt: now,
                    deviceId: "other-device",
                    revision: 5,
                    snapshot: staleRemote
                ),
                repository: repository
            )
            let client = VaultStoreSyncFakeClient(
                downloads: [
                    RemoteSyncResult(payload: firstRemotePayload, statusCode: 200),
                    RemoteSyncResult(payload: laterRemotePayload, statusCode: 200)
                ],
                uploadStatusCodes: [200, 200]
            )

            await store.syncNow(client: client)
            #expect(store.categories == [])
            #expect(!store.syncSettings.hasLocalChanges)

            await store.syncNow(client: client)
            #expect(store.categories == [])
            #expect(store.categoryTemplates == [])
            #expect(client.uploadedPayloads.count == 2)
            let deletionPayload = try decodeEncryptedSyncPayload(
                client.uploadedPayloads.last,
                repository: repository
            )
            let tombstone = try #require(deletionPayload.snapshot.categoryStates.first)
            #expect(tombstone.name == "test")
            #expect(tombstone.isDeleted)

            #expect(store.addCategory("test"))
            let recreationClient = VaultStoreSyncFakeClient(
                downloads: [RemoteSyncResult(payload: client.uploadedPayloads.last, statusCode: 200)],
                uploadStatusCodes: [200]
            )
            await store.syncNow(client: recreationClient)

            #expect(store.categories == ["test"])
            let recreatedPayload = try decodeEncryptedSyncPayload(
                recreationClient.uploadedPayloads.first,
                repository: repository
            )
            let activeState = try #require(recreatedPayload.snapshot.categoryStates.first)
            #expect(activeState.name == "test")
            #expect(!activeState.isDeleted)
            #expect(activeState.version["mac-device", default: 0] > tombstone.version["mac-device", default: 0])
        }
    }

    @MainActor
    @Test("VaultStore ignores stale sync result when local category changes during sync")
    func vaultStoreIgnoresStaleSyncResultWhenLocalCategoryChangesDuringSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSVaultStoreSyncRaceCategoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = InMemorySyncSecretStore()
        let syncRepository = try SyncSettingsRepository(baseDirectory: directory, secretStore: secretStore)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: syncRepository,
            syncEngine: engine
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com/root"
        settings.webdavPath = "/vault.json"
        settings.conflictStrategy = .keepBoth
        settings.lastSyncRevision = 2
        store.updateSyncSettings(settings)
        #expect(store.addCategory("test"))

        let staleRemote = VaultSnapshot(
            entries: [],
            categories: ["test"],
            categoryTemplates: [CategoryTemplate(category: "test")],
            tags: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 3,
                snapshot: staleRemote
            )
        )
        let client = BlockingVaultStoreSyncFakeClient(
            downloads: [
                RemoteSyncResult(payload: remotePayload, statusCode: 200),
                RemoteSyncResult(payload: remotePayload, statusCode: 200)
            ],
            uploadStatusCodes: [200]
        )

        async let syncTask: Void = store.syncNow(client: client)
        await client.waitForDownloadAttempt()
        #expect(store.hasSyncInProgressForTesting())
        #expect(store.deleteCategory("test"))
        #expect(store.syncWasRequestedAgainForTesting())
        client.releaseDownload()
        await syncTask

        #expect(store.categories == [])
        #expect(store.categoryTemplates == [])
        #expect(client.uploadedPayloads.count == 1)
        let uploaded = try decodeEncryptedSyncPayload(client.uploadedPayloads.first, repository: repository)
        #expect(uploaded.revision == 4)
        #expect(uploaded.snapshot.categories == [])
        #expect(uploaded.snapshot.categoryTemplates == [])
    }
}

private func decodeEncryptedSyncPayload(
    _ rawPayload: String?,
    repository: FileVaultRepository,
    password: String = "test-password"
) throws -> VaultSyncPayload {
    let rawPayload = try #require(rawPayload)
    let decoder = makeSyncPayloadDecoder()
    let data = try #require(rawPayload.data(using: .utf8))
    let envelope = try decoder.decode(TestEncryptedVaultSyncEnvelope.self, from: data)
    let masterKeyRecord = try #require(try repository.loadEnvelope()?.masterKeyRecord)
    let crypto = VaultCryptoService()
    let key = try crypto.verify(password: password, record: masterKeyRecord)
    let snapshot = try decoder.decode(VaultSnapshot.self, from: crypto.decrypt(envelope.encryptedVault, key: key))
    return VaultSyncPayload(
        version: envelope.version,
        exportedAt: envelope.exportedAt,
        deviceId: envelope.deviceId,
        revision: envelope.revision,
        snapshot: snapshot
    )
}

private func encodeEncryptedSyncPayload(
    _ payload: VaultSyncPayload,
    repository: FileVaultRepository,
    password: String = "test-password"
) throws -> String {
    let encoder = makeSyncPayloadEncoder()
    let masterKeyRecord = try #require(try repository.loadEnvelope()?.masterKeyRecord)
    let crypto = VaultCryptoService()
    let key = try crypto.verify(password: password, record: masterKeyRecord)
    let envelope = TestEncryptedVaultSyncEnvelope(
        version: payload.version,
        exportedAt: payload.exportedAt,
        deviceId: payload.deviceId,
        revision: payload.revision,
        masterKeyRecord: nil,
        encryptedVault: try crypto.encrypt(try encoder.encode(payload.snapshot), key: key)
    )
    return String(data: try encoder.encode(envelope), encoding: .utf8) ?? "{}"
}

private struct TestEncryptedVaultSyncEnvelope: Codable {
    var version: Int
    var exportedAt: Date
    var deviceId: String
    var revision: Int
    var masterKeyRecord: MasterKeyRecord?
    var encryptedVault: EncryptedPayloadRecord
}

private func makeSyncPayloadEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func makeSyncPayloadDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func syncSettingsHTTPResult(url: URL, statusCode: Int, body: String = "") -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    )
}

private final class SyncSettingsFakeRemoteSyncTransport: RemoteSyncHTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var responses: [Result<(Data, HTTPURLResponse), Error>]

    init(responses: [Result<(Data, HTTPURLResponse), Error>]) {
        self.responses = responses
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return try responses.removeFirst().get()
    }
}

private final class VaultStoreSyncFakeClient: RemoteSyncClient, @unchecked Sendable {
    private var downloads: [RemoteSyncResult]
    private var uploadStatusCodes: [Int]
    private(set) var uploadedPayloads: [String] = []

    init(downloads: [RemoteSyncResult], uploadStatusCodes: [Int]) {
        self.downloads = downloads
        self.uploadStatusCodes = uploadStatusCodes
    }

    func download() async -> RemoteSyncResult {
        downloads.isEmpty ? RemoteSyncResult(payload: nil, statusCode: 404) : downloads.removeFirst()
    }

    func upload(_ payload: String) async -> RemoteSyncResult {
        uploadedPayloads.append(payload)
        let statusCode = uploadStatusCodes.isEmpty ? 200 : uploadStatusCodes.removeFirst()
        return RemoteSyncResult(payload: nil, statusCode: statusCode)
    }
}

private final class BlockingVaultStoreSyncFakeClient: RemoteSyncClient, @unchecked Sendable {
    private let lock = NSLock()
    private var downloads: [RemoteSyncResult]
    private var uploadStatusCodes: [Int]
    private var firstDownloadStarted = false
    private var shouldReleaseFirstDownload = false
    private var firstDownloadContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var uploadedPayloads: [String] = []

    init(downloads: [RemoteSyncResult], uploadStatusCodes: [Int]) {
        self.downloads = downloads
        self.uploadStatusCodes = uploadStatusCodes
    }

    func waitForDownloadAttempt() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if firstDownloadStarted {
                lock.unlock()
                continuation.resume()
            } else {
                firstDownloadContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseDownload() {
        lock.lock()
        shouldReleaseFirstDownload = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func download() async -> RemoteSyncResult {
        let shouldWait = markDownloadStarted()
        if shouldWait {
            await waitForRelease()
        }
        return nextDownloadResult()
    }

    func upload(_ payload: String) async -> RemoteSyncResult {
        RemoteSyncResult(payload: nil, statusCode: recordUploadAndStatus(payload))
    }

    private func nextDownloadResult() -> RemoteSyncResult {
        lock.lock()
        let result = downloads.isEmpty ? RemoteSyncResult(payload: nil, statusCode: 404) : downloads.removeFirst()
        lock.unlock()
        return result
    }

    private func recordUploadAndStatus(_ payload: String) -> Int {
        lock.lock()
        uploadedPayloads.append(payload)
        let statusCode = uploadStatusCodes.isEmpty ? 200 : uploadStatusCodes.removeFirst()
        lock.unlock()
        return statusCode
    }

    private func markDownloadStarted() -> Bool {
        lock.lock()
        if firstDownloadStarted {
            lock.unlock()
            return false
        }
        firstDownloadStarted = true
        let continuations = firstDownloadContinuations
        firstDownloadContinuations.removeAll()
        let shouldWait = !shouldReleaseFirstDownload
        lock.unlock()
        continuations.forEach { $0.resume() }
        return shouldWait
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if shouldReleaseFirstDownload {
                lock.unlock()
                continuation.resume()
            } else {
                releaseContinuations.append(continuation)
                lock.unlock()
            }
        }
    }
}
