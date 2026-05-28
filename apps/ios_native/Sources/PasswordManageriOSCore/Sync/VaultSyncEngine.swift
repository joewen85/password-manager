import Foundation

struct VaultSyncPayload: Codable, Equatable, Sendable {
    var version = 1
    var exportedAt: Date
    var deviceId: String
    var revision: Int
    var snapshot: VaultSnapshot
}

struct VaultSyncEngineResult: Equatable, Sendable {
    var snapshot: VaultSnapshot
    var settings: SyncSettings
    var stats: SyncMergeStats
    var uploaded: Bool
    var appliedRemote: Bool
}

enum VaultSyncEngineError: LocalizedError, Equatable, Sendable {
    case downloadFailed(Int)
    case uploadFailed(Int)
    case invalidRemotePayload

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let statusCode):
            "Sync download failed with status \(statusCode)."
        case .uploadFailed(let statusCode):
            "Sync upload failed with status \(statusCode)."
        case .invalidRemotePayload:
            "Remote sync payload is invalid."
        }
    }
}

struct VaultSyncEngine: Sendable {
    var now: @Sendable () -> Date = Date.init
    var idGenerator: @Sendable () -> UUID = UUID.init

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        idGenerator: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.now = now
        self.idGenerator = idGenerator
    }

    func synchronize(
        localSnapshot: VaultSnapshot,
        settings: SyncSettings,
        client: RemoteSyncClient
    ) async throws -> VaultSyncEngineResult {
        let download = await client.download()
        guard Self.isSuccessfulDownload(download.statusCode) else {
            throw VaultSyncEngineError.downloadFailed(download.statusCode)
        }

        let localPayload = VaultSyncPayload(
            exportedAt: now(),
            deviceId: settings.deviceId,
            revision: settings.lastSyncRevision,
            snapshot: localSnapshot
        )

        guard let remotePayload = try decodePayload(download.payload) else {
            try await upload(localPayload, with: client)
            return result(
                snapshot: localSnapshot,
                settings: settings,
                revision: localPayload.revision,
                stats: SyncMergeStats(
                    total: localSnapshot.entries.count,
                    conflicts: 0,
                    deletes: localSnapshot.entries.filter(\.isDeleted).count
                ),
                uploaded: true,
                appliedRemote: false
            )
        }

        let merger = VaultSyncMerger(
            idGenerator: idGenerator,
            conflictLabelBuilder: { entry, isRemote in
                let source = isRemote ? "remote" : "local"
                let who = entry.updatedBy.isEmpty ? "unknown" : entry.updatedBy
                return "(conflict-\(source)-\(who))"
            },
            conflictStrategy: settings.conflictStrategy.mergeStrategy,
            now: now
        )
        let mergeResult = merger.merge(
            localEntries: localSnapshot.entries,
            remoteEntries: remotePayload.snapshot.entries
        )
        let mergedSnapshot = mergeSnapshot(
            local: localSnapshot,
            remote: remotePayload.snapshot,
            entries: mergeResult.entries
        )

        if mergedSnapshot == remotePayload.snapshot {
            return result(
                snapshot: mergedSnapshot,
                settings: settings,
                revision: remotePayload.revision,
                stats: mergeResult.stats,
                uploaded: false,
                appliedRemote: mergedSnapshot != localSnapshot
            )
        }

        let mergedRevision = max(localPayload.revision, remotePayload.revision) + 1
        let payload = VaultSyncPayload(
            exportedAt: now(),
            deviceId: settings.deviceId,
            revision: mergedRevision,
            snapshot: mergedSnapshot
        )
        try await upload(payload, with: client)
        return result(
            snapshot: mergedSnapshot,
            settings: settings,
            revision: mergedRevision,
            stats: mergeResult.stats,
            uploaded: true,
            appliedRemote: mergedSnapshot != localSnapshot
        )
    }

    func encodePayload(_ payload: VaultSyncPayload) throws -> String {
        String(data: try Self.makeEncoder().encode(payload), encoding: .utf8) ?? "{}"
    }

    func decodePayload(_ rawPayload: String?) throws -> VaultSyncPayload? {
        guard let rawPayload, !rawPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = rawPayload.data(using: .utf8) else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        do {
            return try Self.makeDecoder().decode(VaultSyncPayload.self, from: data)
        } catch {
            throw VaultSyncEngineError.invalidRemotePayload
        }
    }

    private func upload(_ payload: VaultSyncPayload, with client: RemoteSyncClient) async throws {
        let upload = await client.upload(try encodePayload(payload))
        guard upload.statusCode >= 200 && upload.statusCode < 300 else {
            throw VaultSyncEngineError.uploadFailed(upload.statusCode)
        }
    }

    private func mergeSnapshot(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        entries: [VaultEntry]
    ) -> VaultSnapshot {
        let latestSnapshot = local.updatedAt >= remote.updatedAt ? local : remote
        return VaultSnapshot(
            entries: entries.sorted { $0.updatedAt > $1.updatedAt },
            categories: Array(Set(local.categories).union(remote.categories)).sorted(),
            tags: Array(Set(local.tags).union(remote.tags)).sorted(),
            security: latestSnapshot.security,
            syncStatus: latestSnapshot.syncStatus,
            lastBackupStatus: latestSnapshot.lastBackupStatus,
            updatedAt: max(local.updatedAt, remote.updatedAt)
        )
    }

    private func result(
        snapshot: VaultSnapshot,
        settings: SyncSettings,
        revision: Int,
        stats: SyncMergeStats,
        uploaded: Bool,
        appliedRemote: Bool
    ) -> VaultSyncEngineResult {
        var updatedSettings = settings
        updatedSettings.lastSyncRevision = revision
        updatedSettings.lastSyncAt = now()
        updatedSettings.lastSyncStatus = "success"
        updatedSettings.lastSyncMessage = "Synced \(stats.total) items, \(stats.conflicts) conflicts, \(stats.deletes) deletes, revision \(revision)."
        updatedSettings.logs = ([SyncLogEntry(
            timestamp: now(),
            message: updatedSettings.lastSyncMessage ?? "",
            level: "info"
        )] + settings.logs).prefix(50).map { $0 }
        return VaultSyncEngineResult(
            snapshot: snapshot,
            settings: updatedSettings,
            stats: stats,
            uploaded: uploaded,
            appliedRemote: appliedRemote
        )
    }

    private static func isSuccessfulDownload(_ statusCode: Int) -> Bool {
        (statusCode >= 200 && statusCode < 300) || statusCode == 404
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
