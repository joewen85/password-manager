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
    case syncCancelled

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let statusCode):
            "Sync download failed with status \(statusCode)."
        case .uploadFailed(let statusCode):
            "Sync upload failed with status \(statusCode)."
        case .invalidRemotePayload:
            "Remote sync payload is invalid."
        case .syncCancelled:
            "Sync was cancelled because local data changed."
        }
    }
}

struct VaultSyncEngine: Sendable {
    var now: @Sendable () -> Date = Date.init
    var idGenerator: @Sendable () -> String = { UUID().uuidString.lowercased() }

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.now = now
        self.idGenerator = idGenerator
    }

    func synchronize(
        localSnapshot: VaultSnapshot,
        settings: SyncSettings,
        client: RemoteSyncClient,
        shouldCancelUpload: @Sendable () async -> Bool = { false }
    ) async throws -> VaultSyncEngineResult {
        let hasSyncBaseline = hasEstablishedSyncBaseline(settings)
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

        guard let remotePayload = try decodePayload(download.payload) else {
            try await upload(localPayload, with: client, shouldCancelUpload: shouldCancelUpload)
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

        if hasSyncBaseline,
           settings.hasLocalChanges,
           remotePayload.revision <= settings.lastSyncRevision {
            let nextRevision = settings.lastSyncRevision + 1
            let uploadPayload = VaultSyncPayload(
                exportedAt: now(),
                deviceId: settings.deviceId,
                revision: nextRevision,
                snapshot: localSnapshot
            )
            try await upload(uploadPayload, with: client, shouldCancelUpload: shouldCancelUpload)
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
            hasSyncBaseline: hasSyncBaseline,
            localHasChanges: settings.hasLocalChanges,
            conflictStrategy: settings.conflictStrategy,
            localDeviceId: settings.deviceId,
            remoteDeviceId: remotePayload.deviceId
        )

        if hasSameSyncBusinessContent(mergedSnapshot, remotePayload.snapshot) {
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
        try await upload(payload, with: client, shouldCancelUpload: shouldCancelUpload)
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

    private func upload(
        _ payload: VaultSyncPayload,
        with client: RemoteSyncClient,
        shouldCancelUpload: @Sendable () async -> Bool
    ) async throws {
        guard await !shouldCancelUpload() else {
            throw VaultSyncEngineError.syncCancelled
        }
        let upload = await client.upload(try encodePayload(payload))
        guard upload.statusCode >= 200 && upload.statusCode < 300 else {
            throw VaultSyncEngineError.uploadFailed(upload.statusCode)
        }
    }

    private func mergeSnapshot(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        entries: [VaultEntry],
        hasSyncBaseline: Bool,
        localHasChanges: Bool,
        conflictStrategy: SyncSettingsConflictStrategy,
        localDeviceId: String,
        remoteDeviceId: String
    ) -> VaultSnapshot {
        let latestSnapshot = local.updatedAt >= remote.updatedAt ? local : remote
        let categoryStates = mergeCategoryStates(
            local: local,
            remote: remote,
            hasSyncBaseline: hasSyncBaseline,
            localHasChanges: localHasChanges,
            conflictStrategy: conflictStrategy,
            localDeviceId: localDeviceId,
            remoteDeviceId: remoteDeviceId
        )
        let deletedCategoryKeys = Set(categoryStates.compactMap { state in
            state.isDeleted ? normalizedCategoryKey(state.name) : nil
        })
        let normalizedEntries = clearDeletedCategoryReferences(
            entries,
            deletedCategoryKeys: deletedCategoryKeys,
            deviceId: localDeviceId
        )
        let activeEntries = normalizedEntries.filter { !$0.isDeleted }
        let shouldMergeCleanLocalTaxonomy = conflictStrategy == .keepBoth && !localHasChanges
        let baseCategoryTemplates = shouldMergeCleanLocalTaxonomy
            ? remote.categoryTemplates + local.categoryTemplates
            : (localHasChanges ? local.categoryTemplates : remote.categoryTemplates)
        let categories = mergeTaxonomy(
            base: categoryStates.compactMap { $0.isDeleted ? nil : $0.name },
            values: activeEntries.map(\.payload.category) + baseCategoryTemplates.map(\.category)
        ).filter { !deletedCategoryKeys.contains(normalizedCategoryKey($0)) }
        let baseTags = shouldMergeCleanLocalTaxonomy
            ? local.tags + remote.tags
            : (localHasChanges ? local.tags : remote.tags)
        let tags = mergeTaxonomy(
            base: baseTags,
            values: activeEntries.flatMap(\.payload.tags)
        )
        let categoryTemplates = mergeCategoryTemplates(
            local: local,
            remote: remote,
            categories: categories,
            conflictStrategy: conflictStrategy
        )
        return VaultSnapshot(
            entries: normalizedEntries.sorted { $0.updatedAt > $1.updatedAt },
            categories: categories,
            categoryTemplates: categoryTemplates,
            categoryStates: categoryStates,
            tags: tags,
            security: latestSnapshot.security,
            syncStatus: latestSnapshot.syncStatus,
            lastBackupStatus: latestSnapshot.lastBackupStatus,
            updatedAt: max(local.updatedAt, remote.updatedAt)
        )
    }

    private func mergeCategoryStates(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        hasSyncBaseline: Bool,
        localHasChanges: Bool,
        conflictStrategy: SyncSettingsConflictStrategy,
        localDeviceId: String,
        remoteDeviceId: String
    ) -> [CategorySyncState] {
        var localStates = effectiveCategoryStates(in: local)
        var remoteStates = effectiveCategoryStates(in: remote)

        if hasSyncBaseline, localHasChanges {
            for (key, remoteState) in remoteStates where localStates[key] == nil && !remoteState.isDeleted {
                localStates[key] = categoryTombstone(
                    replacing: remoteState,
                    deviceId: localDeviceId,
                    updatedAt: local.updatedAt
                )
            }
        } else if hasSyncBaseline, conflictStrategy == .remoteWins {
            for (key, localState) in localStates where remoteStates[key] == nil && !localState.isDeleted {
                remoteStates[key] = categoryTombstone(
                    replacing: localState,
                    deviceId: remoteDeviceId,
                    updatedAt: remote.updatedAt
                )
            }
        }

        var merged: [CategorySyncState] = []
        for key in Set(localStates.keys).union(remoteStates.keys) {
            switch (localStates[key], remoteStates[key]) {
            case (.some(let localState), .some(let remoteState)):
                merged.append(resolveCategoryState(
                    local: localState,
                    remote: remoteState,
                    conflictStrategy: conflictStrategy
                ))
            case (.some(let localState), .none):
                merged.append(localState)
            case (.none, .some(let remoteState)):
                merged.append(remoteState)
            case (.none, .none):
                break
            }
        }
        return merged.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func hasEstablishedSyncBaseline(_ settings: SyncSettings) -> Bool {
        settings.lastSyncRevision > 0
            || !(settings.lastRemoteFingerprint ?? "").isEmpty
            || (settings.lastSyncAt != nil && settings.lastSyncStatus == "success")
    }

    private func effectiveCategoryStates(in snapshot: VaultSnapshot) -> [String: CategorySyncState] {
        var states: [String: CategorySyncState] = [:]
        for rawState in snapshot.categoryStates {
            let name = rawState.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let updater = rawState.updatedBy.isEmpty ? "legacy" : rawState.updatedBy
            let state = CategorySyncState(
                name: name,
                isDeleted: rawState.isDeleted,
                updatedAt: rawState.updatedAt,
                version: rawState.version.isEmpty ? [updater: 1] : rawState.version,
                updatedBy: updater
            )
            let key = normalizedCategoryKey(name)
            if let existing = states[key] {
                states[key] = resolveCategoryState(
                    local: existing,
                    remote: state,
                    conflictStrategy: .keepBoth
                )
            } else {
                states[key] = state
            }
        }

        let legacyNames = snapshot.categories
            + snapshot.categoryTemplates.map(\.category)
            + snapshot.entries.filter { !$0.isDeleted }.map(\.payload.category)
        for rawName in legacyNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedCategoryKey(name)
            guard !name.isEmpty, states[key] == nil else { continue }
            states[key] = CategorySyncState(
                name: name,
                updatedAt: snapshot.updatedAt,
                version: ["legacy": 1],
                updatedBy: "legacy"
            )
        }
        return states
    }

    private func resolveCategoryState(
        local: CategorySyncState,
        remote: CategorySyncState,
        conflictStrategy: SyncSettingsConflictStrategy
    ) -> CategorySyncState {
        switch VaultSyncMerger.compareVersion(local: local.version, remote: remote.version) {
        case .localDominates:
            return local
        case .remoteDominates:
            return remote
        case .equal, .concurrent:
            let selected: CategorySyncState
            if local.isDeleted != remote.isDeleted {
                selected = local.isDeleted ? local : remote
            } else {
                switch conflictStrategy {
                case .localWins:
                    selected = local
                case .remoteWins:
                    selected = remote
                case .keepBoth:
                    selected = local.updatedAt >= remote.updatedAt ? local : remote
                }
            }
            var converged = selected
            converged.updatedAt = max(local.updatedAt, remote.updatedAt)
            converged.version = mergedVersion(local.version, remote.version)
            return converged
        }
    }

    private func categoryTombstone(
        replacing state: CategorySyncState,
        deviceId: String,
        updatedAt: Date
    ) -> CategorySyncState {
        let updater = deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "legacy"
            : deviceId
        var version = state.version
        version[updater] = (version[updater] ?? 0) + 1
        return CategorySyncState(
            name: state.name,
            isDeleted: true,
            updatedAt: updatedAt,
            version: version,
            updatedBy: updater
        )
    }

    private func clearDeletedCategoryReferences(
        _ entries: [VaultEntry],
        deletedCategoryKeys: Set<String>,
        deviceId: String
    ) -> [VaultEntry] {
        let updater = deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ios-native"
            : deviceId
        return entries.map { entry in
            let key = normalizedCategoryKey(entry.payload.category)
            guard !entry.isDeleted, deletedCategoryKeys.contains(key) else { return entry }
            var updated = entry
            updated.payload = entry.payload.replacingCategory("", tags: entry.payload.tags)
            updated.updatedAt = now()
            updated.version[updater] = (updated.version[updater] ?? 0) + 1
            updated.updatedBy = updater
            return updated
        }
    }

    private func mergedVersion(_ local: [String: Int], _ remote: [String: Int]) -> [String: Int] {
        Dictionary(
            Set(local.keys).union(remote.keys).map { key in
                (key, max(local[key] ?? 0, remote[key] ?? 0))
            },
            uniquingKeysWith: max
        )
    }

    private func normalizedCategoryKey(_ category: String) -> String {
        category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func mergeTaxonomy(base: [String], values: [String]) -> [String] {
        Array(Set((base + values).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private func mergeCategoryTemplates(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        categories: [String],
        conflictStrategy: SyncSettingsConflictStrategy
    ) -> [CategoryTemplate] {
        func indexedTemplates(_ templates: [CategoryTemplate]) -> [String: CategoryTemplate] {
            Dictionary(templates.map { template in
                (normalizedCategoryKey(template.category), template)
            }, uniquingKeysWith: { first, _ in first })
        }

        let localTemplates = indexedTemplates(local.categoryTemplates)
        let remoteTemplates = indexedTemplates(remote.categoryTemplates)
        let localStates = effectiveCategoryStates(in: local)
        let remoteStates = effectiveCategoryStates(in: remote)

        return categories.map { category in
            let key = normalizedCategoryKey(category)
            let selected: CategoryTemplate?
            switch (localStates[key], remoteStates[key]) {
            case (.some(let localState), .some(let remoteState)):
                switch VaultSyncMerger.compareVersion(local: localState.version, remote: remoteState.version) {
                case .localDominates:
                    selected = localTemplates[key]
                case .remoteDominates:
                    selected = remoteTemplates[key]
                case .equal, .concurrent:
                    switch conflictStrategy {
                    case .localWins:
                        selected = localTemplates[key]
                    case .remoteWins:
                        selected = remoteTemplates[key]
                    case .keepBoth:
                        selected = localState.updatedAt >= remoteState.updatedAt
                            ? localTemplates[key]
                            : remoteTemplates[key]
                    }
                }
            case (.some, .none):
                selected = localTemplates[key]
            case (.none, .some):
                selected = remoteTemplates[key]
            case (.none, .none):
                selected = localTemplates[key] ?? remoteTemplates[key]
            }
            return CategoryTemplate(
                category: category,
                fields: selected?.fields ?? CategoryTemplate.defaultFields
            )
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

    private func hasSameSyncBusinessContent(_ left: VaultSnapshot, _ right: VaultSnapshot) -> Bool {
        left.entries == right.entries
            && left.categories == right.categories
            && left.categoryTemplates == right.categoryTemplates
            && left.categoryStates == right.categoryStates
            && left.tags == right.tags
            && left.security == right.security
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
