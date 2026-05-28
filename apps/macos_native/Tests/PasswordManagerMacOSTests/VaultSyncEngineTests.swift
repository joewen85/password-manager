import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("VaultSyncEngine")
struct VaultSyncEngineTests {
    @Test("Missing remote uploads local payload and records status")
    func missingRemoteUploadsLocalPayload() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        let client = FakeSyncClient(
            downloads: [RemoteSyncResult(payload: nil, statusCode: 404)],
            uploadStatusCodes: [201]
        )
        let snapshot = makeSnapshot(
            entries: [makeEntry(id: "11111111-1111-1111-1111-111111111111", label: "Local", device: "mac")]
        )
        let settings = SyncSettings.defaults(deviceId: "mac-device")

        let result = try await engine.synchronize(
            localSnapshot: snapshot,
            settings: settings,
            client: client
        )

        #expect(result.uploaded)
        #expect(!result.appliedRemote)
        #expect(result.settings.lastSyncRevision == 0)
        #expect(result.settings.lastSyncStatus == "success")
        #expect(client.uploadedPayloads.count == 1)
        let uploaded = try #require(try engine.decodePayload(client.uploadedPayloads.single))
        #expect(uploaded.deviceId == "mac-device")
        #expect(uploaded.snapshot.entries.first?.label == "Local")
    }

    @Test("Remote dominant payload applies locally without uploading")
    func remoteDominantPayloadAppliesWithoutUpload() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.lastSyncRevision = 1
        let local = makeSnapshot(
            entries: [makeEntry(id: "22222222-2222-2222-2222-222222222222", label: "Old", device: "mac", version: ["mac": 1])]
        )
        let remote = makeSnapshot(
            entries: [makeEntry(id: "22222222-2222-2222-2222-222222222222", label: "Remote", device: "remote", version: ["mac": 1, "remote": 1])]
        )
        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 2,
                snapshot: remote
            )
        )
        let client = FakeSyncClient(downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)])

        let result = try await engine.synchronize(localSnapshot: local, settings: settings, client: client)

        #expect(!result.uploaded)
        #expect(result.appliedRemote)
        #expect(result.snapshot.entries.first?.label == "Remote")
        #expect(result.settings.lastSyncRevision == 2)
        #expect(client.uploadedPayloads.isEmpty)
    }

    @Test("Concurrent payload merges and uploads next revision")
    func concurrentPayloadMergesAndUploadsNextRevision() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let conflictId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let engine = VaultSyncEngine(now: { now }, idGenerator: { conflictId })
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.lastSyncRevision = 2
        settings.conflictStrategy = .localWins
        let sharedId = "44444444-4444-4444-4444-444444444444"
        let local = makeSnapshot(
            categories: ["Local"],
            tags: ["mac"],
            entries: [makeEntry(id: sharedId, label: "Local", category: "Local", tags: ["mac"], device: "mac", version: ["mac": 2, "remote": 1])]
        )
        let remote = makeSnapshot(
            categories: ["Remote"],
            tags: ["remote"],
            entries: [makeEntry(id: sharedId, label: "Remote", category: "Remote", tags: ["remote"], device: "remote", version: ["mac": 1, "remote": 2])]
        )
        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 4,
                snapshot: remote
            )
        )
        let client = FakeSyncClient(
            downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        let result = try await engine.synchronize(localSnapshot: local, settings: settings, client: client)

        #expect(result.uploaded)
        #expect(result.appliedRemote)
        #expect(result.settings.lastSyncRevision == 5)
        #expect(result.stats.conflicts == 1)
        #expect(Set(result.snapshot.categories) == ["Local", "Remote"])
        #expect(Set(result.snapshot.tags) == ["mac", "remote"])
        #expect(result.snapshot.entries.count == 2)
        let uploaded = try #require(try engine.decodePayload(client.uploadedPayloads.single))
        #expect(uploaded.revision == 5)
        #expect(uploaded.snapshot.entries.contains { $0.id == conflictId })
    }

    @Test("Flutter v2 encrypted sync payload is decoded with the unlocked master password")
    func flutterEncryptedPayloadDecodesWithFallbackDecoder() async throws {
        let crypto = VaultCryptoService()
        let password = "flutter-sync-password"
        let recordSalt = Data((1...16).map(UInt8.init))
        let metadataSalt = Data((17...32).map(UInt8.init))
        let recordKey = try crypto.deriveKeyForTesting(
            password: password,
            salt: recordSalt,
            iterations: 120_000
        )
        let metadataKey = try crypto.deriveKeyForTesting(
            password: password,
            salt: metadataSalt,
            iterations: 120_000
        )
        let payloadRecord = try crypto.encrypt(
            try jsonData([
                "username": "flutter-user",
                "password": "flutter-secret",
                "token": "flutter-token",
                "appId": "flutter-app",
                "accessKey": "flutter-access",
                "secretKey": "flutter-secret-key",
                "notes": "from flutter sync",
                "category": "Mobile",
                "tags": ["flutter", "sync"]
            ]),
            key: recordKey,
            nonceBytes: Data((33...44).map(UInt8.init))
        )
        let metadataRecord = try crypto.encrypt(
            try jsonData([
                "schemaVersion": 1,
                "label": "Flutter Credential",
                "type": "credential",
                "createdAt": "2026-05-27T05:00:00.000Z",
                "updatedAt": "2026-05-27T05:01:02.123Z",
                "version": ["flutter-device": 7],
                "updatedBy": "flutter-device",
                "isDeleted": false,
                "category": "Mobile",
                "tags": ["flutter", "sync"]
            ]),
            key: metadataKey,
            nonceBytes: Data((45...56).map(UInt8.init))
        )
        let globalMetadataRecord = try crypto.encrypt(
            try jsonData([
                "categories": ["Mobile"],
                "tags": ["flutter", "sync"],
                "sortOrder": "updatedDesc",
                "tagsUpdatedAt": 1_800_000_001_000,
                "categoriesUpdatedAt": 1_800_000_001_000,
                "recordKeyMetadataMigrated": false
            ]),
            key: metadataKey,
            nonceBytes: Data((57...68).map(UInt8.init))
        )
        let rawPayload = try jsonString([
            "version": 2,
            "exportedAt": "2026-05-27T05:02:03.456Z",
            "deviceId": "flutter-device",
            "revision": 7,
            "masterKey": [
                "salt": recordSalt.base64EncodedString(),
                "iterations": 120_000,
                "verifier": recordKey.base64EncodedString(),
                "metadataSalt": metadataSalt.base64EncodedString(),
                "metadataIterations": 120_000
            ],
            "metadataRecord": [
                "encryptedPayload": encryptedPayloadJson(globalMetadataRecord),
                "kdfSalt": metadataSalt.base64EncodedString(),
                "kdfIterations": 120_000
            ],
            "items": [[
                "id": "55555555-6666-7777-8888-999999999999",
                "encryptedPayload": encryptedPayloadJson(payloadRecord),
                "encryptedMetadata": encryptedPayloadJson(metadataRecord),
                "kdfSalt": recordSalt.base64EncodedString(),
                "kdfIterations": 120_000
            ]]
        ])
        let engine = VaultSyncEngine(now: { Date(timeIntervalSince1970: 1_800_000_100) })
        let decoder = FlutterSyncPayloadDecoder(masterPassword: password, crypto: crypto)

        #expect(throws: (any Error).self) {
            _ = try engine.decodePayload(rawPayload)
        }

        let decoded = try #require(try engine.decodePayload(rawPayload, fallbackDecoder: decoder.decode))
        let entry = try #require(decoded.snapshot.entries.first)
        #expect(decoded.deviceId == "flutter-device")
        #expect(decoded.revision == 7)
        #expect(decoded.snapshot.categories == ["Mobile"])
        #expect(decoded.snapshot.tags == ["flutter", "sync"])
        #expect(entry.id.uuidString.lowercased() == "55555555-6666-7777-8888-999999999999")
        #expect(entry.label == "Flutter Credential")
        #expect(entry.updatedBy == "flutter-device")
        #expect(entry.version == ["flutter-device": 7])
        #expect(entry.payload.category == "Mobile")
        #expect(entry.payload.tags == ["flutter", "sync"])
        guard case .credential(let credential) = entry.payload else {
            Issue.record("Expected credential payload")
            return
        }
        #expect(credential.username == "flutter-user")
        #expect(credential.password == "flutter-secret")

        let client = FakeSyncClient(downloads: [RemoteSyncResult(payload: rawPayload, statusCode: 200)])
        let result = try await engine.synchronize(
            localSnapshot: makeSnapshot(entries: [], updatedAt: Date(timeIntervalSince1970: 1)),
            settings: SyncSettings.defaults(deviceId: "mac-device"),
            client: client,
            remotePayloadDecoder: decoder.decode
        )
        #expect(result.appliedRemote)
        #expect(!result.uploaded)
        #expect(result.snapshot.entries.first?.label == "Flutter Credential")
        #expect(result.settings.lastSyncRevision == 7)
    }
}

private final class FakeSyncClient: RemoteSyncClient, @unchecked Sendable {
    private var downloads: [RemoteSyncResult]
    private var uploadStatusCodes: [Int]
    private(set) var uploadedPayloads: [String] = []

    init(downloads: [RemoteSyncResult], uploadStatusCodes: [Int] = []) {
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

private func makeSnapshot(
    categories: [String] = [],
    tags: [String] = [],
    entries: [VaultEntry],
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> VaultSnapshot {
    VaultSnapshot(
        entries: entries,
        categories: categories,
        tags: tags,
        security: SecuritySettings(requireTotp: true, totpSecret: "JBSWY3DPEHPK3PXP"),
        syncStatus: "Idle",
        lastBackupStatus: "No backup has run",
        updatedAt: updatedAt
    )
}

private func makeEntry(
    id: String,
    label: String,
    category: String = "",
    tags: [String] = [],
    device: String,
    version: [String: Int] = [:]
) -> VaultEntry {
    VaultEntry(
        id: UUID(uuidString: id)!,
        label: label,
        type: .credential,
        payload: .credential(
            CredentialPayload(
                username: "\(label.lowercased())@example.com",
                password: "secret",
                tags: tags,
                category: category
            )
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        version: version,
        updatedBy: device
    )
}

private extension Array where Element == String {
    var single: String {
        get throws {
            try #require(count == 1)
            return self[0]
        }
    }
}

private func encryptedPayloadJson(_ payload: EncryptedPayloadRecord) -> [String: Any] {
    [
        "ciphertext": payload.ciphertext,
        "nonce": payload.nonce,
        "mac": payload.mac,
        "version": payload.version
    ]
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func jsonString(_ object: [String: Any]) throws -> String {
    let data = try jsonData(object)
    return try #require(String(data: data, encoding: .utf8))
}
