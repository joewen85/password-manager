import Foundation
import Testing
@testable import PasswordManageriOSCore

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
