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

    @Test("Remote tombstone applies without restoring deleted taxonomy")
    func remoteTombstoneAppliesWithoutRestoringDeletedTaxonomy() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        var settings = SyncSettings.defaults(deviceId: "ios-device")
        settings.lastSyncRevision = 1
        settings.hasLocalChanges = false
        let sharedId = "99999999-9999-9999-9999-999999999999"
        let local = makeSnapshot(
            categories: ["Deleted Category"],
            tags: ["deleted-tag"],
            entries: [
                makeEntry(
                    id: sharedId,
                    label: "Local",
                    category: "Deleted Category",
                    tags: ["deleted-tag"],
                    device: "ios",
                    version: ["ios": 1]
                )
            ]
        )
        let remote = makeSnapshot(
            categories: [],
            tags: [],
            entries: [
                makeEntry(
                    id: sharedId,
                    label: "Local",
                    category: "Deleted Category",
                    tags: ["deleted-tag"],
                    device: "remote",
                    version: ["ios": 1, "remote": 1],
                    isDeleted: true
                )
            ]
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
        #expect(result.snapshot.entries.first?.isDeleted == true)
        #expect(result.snapshot.categories == [])
        #expect(result.snapshot.tags == [])
        #expect(client.uploadedPayloads.isEmpty)
    }

    @Test("Unchanged remote fingerprint skips full download when local is clean")
    func unchangedRemoteFingerprintSkipsFullDownloadWhenLocalIsClean() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.lastRemoteFingerprint = #"etag:"same""#
        settings.hasLocalChanges = false
        let local = makeSnapshot(
            entries: [makeEntry(id: "66666666-6666-6666-6666-666666666666", label: "Local", device: "mac")]
        )
        let client = FakeSyncClient(
            downloads: [RemoteSyncResult(payload: "should-not-download", statusCode: 200)],
            metadata: RemoteSyncMetadata(statusCode: 200, eTag: #""same""#)
        )

        let result = try await engine.synchronize(localSnapshot: local, settings: settings, client: client)

        #expect(!result.uploaded)
        #expect(!result.appliedRemote)
        #expect(client.metadataCount == 1)
        #expect(client.downloadCount == 0)
        #expect(result.settings.lastSyncMessage == "Remote unchanged; skipped full sync download.")
        #expect(result.settings.lastRemoteFingerprint == #"etag:"same""#)
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

    @Test("Local taxonomy deletion is not restored from remote metadata when local has changes")
    func localTaxonomyDeletionIsNotRestoredFromRemoteMetadataWhenLocalHasChanges() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.lastSyncRevision = 2
        settings.hasLocalChanges = true
        let sharedId = "77777777-7777-7777-7777-777777777777"
        let local = makeSnapshot(
            categories: [],
            tags: [],
            entries: [makeEntry(id: sharedId, label: "Local", device: "mac", version: ["mac": 2])]
        )
        let remote = makeSnapshot(
            categories: ["Deleted Category"],
            tags: ["deleted-tag"],
            entries: [makeEntry(id: sharedId, label: "Remote", device: "remote", version: ["mac": 1])]
        )
        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 2,
                snapshot: remote
            )
        )
        let client = FakeSyncClient(
            downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        let result = try await engine.synchronize(localSnapshot: local, settings: settings, client: client)

        #expect(result.uploaded)
        #expect(result.snapshot.categories == [])
        #expect(result.snapshot.tags == [])
        let uploaded = try #require(try engine.decodePayload(client.uploadedPayloads.single))
        #expect(uploaded.snapshot.categories == [])
        #expect(uploaded.snapshot.tags == [])
    }

    @Test("Local changes upload directly when remote revision has not advanced")
    func localChangesUploadDirectlyWhenRemoteRevisionHasNotAdvanced() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = VaultSyncEngine(now: { now })
        var settings = SyncSettings.defaults(deviceId: "mac-device")
        settings.lastSyncRevision = 3
        settings.hasLocalChanges = true
        let sharedId = "88888888-8888-8888-8888-888888888888"
        let local = makeSnapshot(
            categories: [],
            tags: [],
            entries: [
                makeEntry(
                    id: sharedId,
                    label: "Local",
                    category: "",
                    tags: [],
                    device: "mac",
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    version: ["mac": 1]
                )
            ]
        )
        let remote = makeSnapshot(
            categories: ["Old Category"],
            tags: ["old-tag"],
            entries: [
                makeEntry(
                    id: sharedId,
                    label: "Remote",
                    category: "Old Category",
                    tags: ["old-tag"],
                    device: "mac",
                    updatedAt: Date(timeIntervalSince1970: 1_800_003_600),
                    version: ["mac": 1]
                )
            ]
        )
        let remotePayload = try engine.encodePayload(
            VaultSyncPayload(
                exportedAt: now,
                deviceId: "remote-device",
                revision: 3,
                snapshot: remote
            )
        )
        let client = FakeSyncClient(
            downloads: [RemoteSyncResult(payload: remotePayload, statusCode: 200)],
            uploadStatusCodes: [200]
        )

        let result = try await engine.synchronize(localSnapshot: local, settings: settings, client: client)

        #expect(result.uploaded)
        #expect(!result.appliedRemote)
        #expect(result.settings.lastSyncRevision == 4)
        #expect(result.snapshot.categories == [])
        #expect(result.snapshot.tags == [])
        let uploaded = try #require(try engine.decodePayload(client.uploadedPayloads.single))
        #expect(uploaded.revision == 4)
        let uploadedEntry = try #require(uploaded.snapshot.entries.first)
        #expect(uploadedEntry.label == "Local")
        #expect(uploadedEntry.payload.category == "")
        #expect(uploadedEntry.payload.tags == [])
    }
}

private final class FakeSyncClient: RemoteSyncClient, @unchecked Sendable {
    private var downloads: [RemoteSyncResult]
    private var uploadStatusCodes: [Int]
    private var remoteMetadata: RemoteSyncMetadata
    private(set) var uploadedPayloads: [String] = []
    private(set) var downloadCount = 0
    private(set) var metadataCount = 0

    init(
        downloads: [RemoteSyncResult],
        uploadStatusCodes: [Int] = [],
        metadata: RemoteSyncMetadata = RemoteSyncMetadata(statusCode: 501)
    ) {
        self.downloads = downloads
        self.uploadStatusCodes = uploadStatusCodes
        self.remoteMetadata = metadata
    }

    func metadata() async -> RemoteSyncMetadata {
        metadataCount += 1
        return remoteMetadata
    }

    func download() async -> RemoteSyncResult {
        downloadCount += 1
        return downloads.isEmpty ? RemoteSyncResult(payload: nil, statusCode: 404) : downloads.removeFirst()
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
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
    version: [String: Int] = [:],
    isDeleted: Bool = false
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
        updatedAt: updatedAt,
        isDeleted: isDeleted,
        deletedAt: isDeleted ? updatedAt : nil,
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
