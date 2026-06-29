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
        client: RemoteSyncClient,
        remotePayloadDecoder: (@Sendable (String?) throws -> VaultSyncPayload?)? = nil
    ) async throws -> VaultSyncEngineResult {
        let remoteMetadata = await client.metadata()
        let remoteFingerprint = remoteMetadata.fingerprint
        if !settings.hasLocalChanges,
           let remoteFingerprint,
           remoteFingerprint == settings.lastRemoteFingerprint,
           Self.isSuccessfulDownload(remoteMetadata.statusCode) {
            return noChangeResult(
                snapshot: localSnapshot,
                settings: settings,
                remoteFingerprint: remoteFingerprint
            )
        }

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

        guard let remotePayload = try decodePayload(download.payload, fallbackDecoder: remotePayloadDecoder) else {
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
                appliedRemote: false,
                remoteFingerprint: remoteFingerprint
            )
        }

        if settings.hasLocalChanges, remotePayload.revision <= settings.lastSyncRevision {
            let nextRevision = settings.lastSyncRevision + 1
            let uploadPayload = VaultSyncPayload(
                exportedAt: now(),
                deviceId: settings.deviceId,
                revision: nextRevision,
                snapshot: localSnapshot
            )
            try await upload(uploadPayload, with: client)
            return result(
                snapshot: localSnapshot,
                settings: settings,
                revision: nextRevision,
                stats: SyncMergeStats(
                    total: localSnapshot.entries.count,
                    conflicts: 0,
                    deletes: localSnapshot.entries.filter(\.isDeleted).count
                ),
                uploaded: true,
                appliedRemote: false,
                remoteFingerprint: nil
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
            entries: mergeResult.entries,
            localHasChanges: settings.hasLocalChanges,
            conflictStrategy: settings.conflictStrategy
        )

        if mergedSnapshot == remotePayload.snapshot {
            return result(
                snapshot: mergedSnapshot,
                settings: settings,
                revision: remotePayload.revision,
                stats: mergeResult.stats,
                uploaded: false,
                appliedRemote: mergedSnapshot != localSnapshot,
                remoteFingerprint: remoteFingerprint
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
            appliedRemote: mergedSnapshot != localSnapshot,
            remoteFingerprint: nil
        )
    }

    func encodePayload(_ payload: VaultSyncPayload) throws -> String {
        String(data: try Self.makeEncoder().encode(payload), encoding: .utf8) ?? "{}"
    }

    func decodePayload(
        _ rawPayload: String?,
        fallbackDecoder: (@Sendable (String?) throws -> VaultSyncPayload?)? = nil
    ) throws -> VaultSyncPayload? {
        guard let rawPayload, !rawPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = rawPayload.data(using: .utf8) else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        do {
            return try Self.makeDecoder().decode(VaultSyncPayload.self, from: data)
        } catch {
            if let fallbackPayload = try fallbackDecoder?(rawPayload) {
                return fallbackPayload
            }
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
        entries: [VaultEntry],
        localHasChanges: Bool,
        conflictStrategy: SyncSettingsConflictStrategy
    ) -> VaultSnapshot {
        let latestSnapshot = local.updatedAt >= remote.updatedAt ? local : remote
        let activeEntries = entries.filter { !$0.isDeleted }
        let keepBothTaxonomy = conflictStrategy == .keepBoth
        let baseCategories = keepBothTaxonomy
            ? local.categories + remote.categories
            : (localHasChanges ? local.categories : remote.categories)
        let baseCategoryTemplates = keepBothTaxonomy
            ? preferredTemplates(local: local, remote: remote, localHasChanges: localHasChanges)
            : (localHasChanges ? local.categoryTemplates : remote.categoryTemplates)
        let categories = mergeTaxonomy(
            base: baseCategories,
            values: activeEntries.map(\.payload.category) + baseCategoryTemplates.map(\.category)
        )
        let baseTags = keepBothTaxonomy
            ? local.tags + remote.tags
            : (localHasChanges ? local.tags : remote.tags)
        let tags = mergeTaxonomy(
            base: baseTags,
            values: activeEntries.flatMap(\.payload.tags)
        )
        let categoryTemplates = mergeCategoryTemplates(
            base: baseCategoryTemplates,
            local: local.categoryTemplates,
            remote: remote.categoryTemplates,
            categories: categories
        )
        return VaultSnapshot(
            entries: entries.sorted { $0.updatedAt > $1.updatedAt },
            categories: categories,
            categoryTemplates: categoryTemplates,
            tags: tags,
            security: latestSnapshot.security,
            syncStatus: latestSnapshot.syncStatus,
            lastBackupStatus: latestSnapshot.lastBackupStatus,
            updatedAt: max(local.updatedAt, remote.updatedAt)
        )
    }

    private func preferredTemplates(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        localHasChanges: Bool
    ) -> [CategoryTemplate] {
        localHasChanges
            ? local.categoryTemplates + remote.categoryTemplates
            : remote.categoryTemplates + local.categoryTemplates
    }

    private func mergeTaxonomy(base: [String], values: [String]) -> [String] {
        Array(Set((base + values).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private func mergeCategoryTemplates(
        base: [CategoryTemplate],
        local: [CategoryTemplate],
        remote: [CategoryTemplate],
        categories: [String]
    ) -> [CategoryTemplate] {
        let categoryKeys = Set(categories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var templatesByCategory: [String: CategoryTemplate] = [:]

        func insert(_ template: CategoryTemplate) {
            let category = template.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = category.lowercased()
            guard !category.isEmpty, categoryKeys.contains(key), templatesByCategory[key] == nil else {
                return
            }
            templatesByCategory[key] = CategoryTemplate(category: category, fields: template.fields)
        }

        base.forEach(insert)
        local.forEach(insert)
        remote.forEach(insert)

        return categories.compactMap { category in
            let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return templatesByCategory[key]
        }
    }

    private func result(
        snapshot: VaultSnapshot,
        settings: SyncSettings,
        revision: Int,
        stats: SyncMergeStats,
        uploaded: Bool,
        appliedRemote: Bool,
        remoteFingerprint: String?
    ) -> VaultSyncEngineResult {
        var updatedSettings = settings
        updatedSettings.lastSyncRevision = revision
        updatedSettings.lastSyncAt = now()
        updatedSettings.lastSyncStatus = "success"
        updatedSettings.lastSyncMessage = "Synced \(stats.total) items, \(stats.conflicts) conflicts, \(stats.deletes) deletes, revision \(revision)."
        updatedSettings.lastRemoteFingerprint = remoteFingerprint
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

    private func noChangeResult(
        snapshot: VaultSnapshot,
        settings: SyncSettings,
        remoteFingerprint: String
    ) -> VaultSyncEngineResult {
        var updatedSettings = settings
        updatedSettings.lastSyncAt = now()
        updatedSettings.lastSyncStatus = "success"
        updatedSettings.lastSyncMessage = "Remote unchanged; skipped full sync download."
        updatedSettings.lastRemoteFingerprint = remoteFingerprint
        updatedSettings.logs = ([SyncLogEntry(
            timestamp: now(),
            message: updatedSettings.lastSyncMessage ?? "",
            level: "info"
        )] + settings.logs).prefix(50).map { $0 }
        return VaultSyncEngineResult(
            snapshot: snapshot,
            settings: updatedSettings,
            stats: SyncMergeStats(
                total: snapshot.entries.count,
                conflicts: 0,
                deletes: snapshot.entries.filter(\.isDeleted).count
            ),
            uploaded: false,
            appliedRemote: false
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
