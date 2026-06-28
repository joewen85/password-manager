import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("SyncSettings")
struct SyncSettingsTests {
    @Test("Defaults match Flutter sync settings contract")
    func defaultsMatchFlutterContract() {
        let settings = SyncSettings.defaults(deviceId: "device-1")

        #expect(settings.providerType == .none)
        #expect(settings.webdavPath == "/vault.json")
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
        #expect(settings.objectKey == "vault.sync.json")
        #expect(settings.ak.isEmpty)
        #expect(settings.sk.isEmpty)
    }

    @Test("Decoding tolerates missing and unknown values")
    func decodingToleratesMissingAndUnknownValues() throws {
        let data = Data(
            """
            {
              "providerType": "futureProvider",
              "webdavUrl": "https://dav.example.com",
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let encoded = try encoder.encode(settings)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let json = try #require(object)

        #expect(json["providerType"] as? String == "none")
        #expect(json["webdavPath"] as? String == "/vault.json")
        #expect(json["autoSyncIntervalMinutes"] as? Int == 1)
        #expect(json["autoSyncIntervalValue"] as? Int == 30)
        #expect(json["autoSyncIntervalUnit"] as? String == "seconds")
        #expect(json["lastRemoteFingerprint"] as? String == "etag:remote-v1")
        #expect(json["conflictStrategy"] as? String == "remoteWins")
        #expect(json["syncMasterKey"] as? Bool == true)
        #expect(json["objectKey"] as? String == "vault.sync.json")
        #expect(json["ak"] as? String == "")
        #expect(json["sk"] as? String == "")
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
                    url: URL(string: "https://bucket-1250000000.cos.ap-shanghai.myqcloud.com/folder/vault.json")!,
                    statusCode: 200,
                    body: "{}"
                )),
                .success(syncSettingsHTTPResult(
                    url: URL(string: "https://bucket.oss-cn-hangzhou.aliyuncs.com/folder/vault.json")!,
                    statusCode: 201
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
        var cos = SyncSettings.defaults(deviceId: "device-1")
        cos.providerType = .tencentCos
        cos.ak = "cos-ak"
        cos.sk = "cos-sk"
        cos.bucket = "bucket"
        cos.appid = "1250000000"
        cos.endpoint = "https://cos.ap-shanghai.myqcloud.com"
        cos.objectKey = "folder/vault.json"
        var oss = SyncSettings.defaults(deviceId: "device-1")
        oss.providerType = .aliyunOss
        oss.ak = "oss-ak"
        oss.sk = "oss-sk"
        oss.bucket = "bucket"
        oss.endpoint = "https://oss-cn-hangzhou.aliyuncs.com"
        oss.objectKey = "folder/vault.json"

        let missing = factory.makeClient(settings: .defaults(deviceId: "device-1"), transport: transport)
        let webdavClient = factory.makeClient(settings: webdav, transport: transport)
        let presignedClient = factory.makeClient(settings: presigned, transport: transport)
        let missingObjectStorageClient = factory.makeClient(
            settings: {
                var settings = SyncSettings.defaults(deviceId: "device-1")
                settings.providerType = .tencentCos
                settings.ak = "ak"
                settings.sk = "sk"
                return settings
            }(),
            transport: transport
        )
        let cosClient = factory.makeClient(settings: cos, transport: transport)
        let ossClient = factory.makeClient(settings: oss, transport: transport)

        #expect(missing == nil)
        #expect(webdavClient != nil)
        #expect(presignedClient != nil)
        #expect(missingObjectStorageClient == nil)
        #expect(cosClient != nil)
        #expect(ossClient != nil)
        let webdavResult = await webdavClient?.download()
        let presignedResult = await presignedClient?.upload("{}")
        let cosResult = await cosClient?.download()
        let ossResult = await ossClient?.upload("{}")
        #expect(webdavResult == RemoteSyncResult(payload: "{}", statusCode: 200))
        #expect(presignedResult == RemoteSyncResult(payload: nil, statusCode: 201))
        #expect(cosResult == RemoteSyncResult(payload: "{}", statusCode: 200))
        #expect(ossResult == RemoteSyncResult(payload: nil, statusCode: 201))
        #expect(transport.requests[0].url?.absoluteString == "https://dav.example.com/root/vault.json")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
        #expect(transport.requests[1].url?.absoluteString == "https://upload.example.com/vault")
        #expect(transport.requests[2].url?.absoluteString == "https://bucket-1250000000.cos.ap-shanghai.myqcloud.com/folder/vault.json")
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization")?.contains("q-ak=cos-ak") == true)
        #expect(transport.requests[3].url?.absoluteString == "https://bucket.oss-cn-hangzhou.aliyuncs.com/folder/vault.json")
        #expect(transport.requests[3].value(forHTTPHeaderField: "Authorization")?.hasPrefix("OSS4-HMAC-SHA256 Credential=oss-ak/") == true)
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
        settings.ak = "access-key"
        settings.sk = "secret-key"
        settings.bucket = "bucket"
        settings.endpoint = "https://endpoint.example.com"
        settings.appid = "1250000000"
        settings.customUrl = "https://custom.example.com"
        settings.objectKey = "folder/vault.json"

        try repository.save(settings)

        let optionalRawFile = try repository.rawSettingsFile()
        let rawFile = try #require(optionalRawFile)
        #expect(rawFile.contains("\"providerType\" : \"webdav\""))
        #expect(rawFile.contains("\"webdavUsername\" : \"alice\""))
        #expect(!rawFile.contains("webdav-password"))
        #expect(!rawFile.contains("https://download.example.com/vault"))
        #expect(!rawFile.contains("https://upload.example.com/vault"))
        #expect(!rawFile.contains("access-key"))
        #expect(!rawFile.contains("secret-key"))
        #expect(rawFile.contains("\"bucket\" : \"bucket\""))
        #expect(rawFile.contains("\"objectKey\" : \"folder\\/vault.json\""))
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
        let uploaded = try #require(try engine.decodePayload(client.uploadedPayloads.first))
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
