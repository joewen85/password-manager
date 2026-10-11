import Foundation

enum VersionComparison: Sendable {
    case equal
    case localDominates
    case remoteDominates
    case concurrent
}

enum SyncConflictStrategy: Sendable {
    case localWins
    case remoteWins
    case keepBoth
}

struct SyncMergeStats: Equatable, Sendable {
    var total: Int
    var conflicts: Int
    var deletes: Int
}

struct SyncMergeResult: Equatable, Sendable {
    var entries: [VaultEntry]
    var stats: SyncMergeStats
}

struct VaultSyncMerger {
    var idGenerator: () -> String = { UUID().uuidString.lowercased() }
    var conflictLabelBuilder: (VaultEntry, Bool) -> String = { _, _ in "(conflict)" }
    var conflictStrategy: SyncConflictStrategy = .keepBoth
    var now: () -> Date = Date.init

    func merge(localEntries: [VaultEntry], remoteEntries: [VaultEntry]) -> SyncMergeResult {
        var merged: [VaultEntry] = []
        var conflicts = 0
        var deletes = 0

        func addEntry(_ entry: VaultEntry) {
            merged.append(entry)
            if entry.isDeleted {
                deletes += 1
            }
        }

        var versionCache: [String: [String: Int]] = [:]
        func effectiveVersion(_ entry: VaultEntry) -> [String: Int] {
            if !entry.version.isEmpty {
                return entry.version
            }
            if let cached = versionCache[entry.id] {
                return cached
            }
            let updater = entry.updatedBy.isEmpty ? Self.legacyUpdater : entry.updatedBy
            let version = [updater: 1]
            versionCache[entry.id] = version
            return version
        }

        var remoteById = entriesById(remoteEntries, effectiveVersion: effectiveVersion)
        let localById = entriesById(localEntries, effectiveVersion: effectiveVersion)

        for (id, local) in localById {
            guard let remote = remoteById.removeValue(forKey: id) else {
                addEntry(local)
                continue
            }

            switch Self.compareVersion(local: effectiveVersion(local), remote: effectiveVersion(remote)) {
            case .equal:
                addEntry(pickLatest(local: local, remote: remote))
            case .localDominates:
                addEntry(local)
            case .remoteDominates:
                addEntry(remote)
            case .concurrent:
                if local.isDeleted != remote.isDeleted {
                    conflicts += 1
                    let deleted = local.isDeleted ? local : remote
                    let active = local.isDeleted ? remote : local
                    addEntry(deleted)
                    merged.append(conflictClone(active, isRemote: active.id == remote.id && active == remote))
                } else if samePayload(local: local, remote: remote) {
                    addEntry(pickLatest(local: local, remote: remote))
                } else {
                    conflicts += 1
                    let primary = choosePrimary(local: local, remote: remote)
                    let secondary = primary == local ? remote : local
                    merged.append(primary)
                    merged.append(conflictClone(secondary, isRemote: secondary == remote))
                }
            }
        }

        for remote in remoteById.values {
            addEntry(remote)
        }

        return SyncMergeResult(
            entries: merged,
            stats: SyncMergeStats(total: merged.count, conflicts: conflicts, deletes: deletes)
        )
    }

    static func compareVersion(local: [String: Int], remote: [String: Int]) -> VersionComparison {
        var localGreater = false
        var remoteGreater = false
        for key in Set(local.keys).union(remote.keys) {
            let localValue = local[key] ?? 0
            let remoteValue = remote[key] ?? 0
            if localValue > remoteValue {
                localGreater = true
            } else if remoteValue > localValue {
                remoteGreater = true
            }
            if localGreater && remoteGreater {
                return .concurrent
            }
        }
        if !localGreater && !remoteGreater {
            return .equal
        }
        return localGreater ? .localDominates : .remoteDominates
    }

    private func pickLatest(local: VaultEntry, remote: VaultEntry) -> VaultEntry {
        local.updatedAt >= remote.updatedAt ? local : remote
    }

    private func samePayload(local: VaultEntry, remote: VaultEntry) -> Bool {
        local.label == remote.label &&
            local.type == remote.type &&
            local.payload == remote.payload &&
            local.customFields == remote.customFields &&
            local.isDeleted == remote.isDeleted
    }

    private func choosePrimary(local: VaultEntry, remote: VaultEntry) -> VaultEntry {
        switch conflictStrategy {
        case .localWins:
            local
        case .remoteWins:
            remote
        case .keepBoth:
            pickLatest(local: local, remote: remote)
        }
    }

    private func entriesById(
        _ entries: [VaultEntry],
        effectiveVersion: (VaultEntry) -> [String: Int]
    ) -> [String: VaultEntry] {
        var entriesById: [String: VaultEntry] = [:]
        for entry in entries {
            guard let existing = entriesById[entry.id] else {
                entriesById[entry.id] = entry
                continue
            }
            entriesById[entry.id] = pickDuplicate(
                existing: existing,
                candidate: entry,
                effectiveVersion: effectiveVersion
            )
        }
        return entriesById
    }

    private func pickDuplicate(
        existing: VaultEntry,
        candidate: VaultEntry,
        effectiveVersion: (VaultEntry) -> [String: Int]
    ) -> VaultEntry {
        switch Self.compareVersion(local: effectiveVersion(existing), remote: effectiveVersion(candidate)) {
        case .equal:
            pickLatest(local: existing, remote: candidate)
        case .localDominates:
            existing
        case .remoteDominates:
            candidate
        case .concurrent:
            pickLatest(local: existing, remote: candidate)
        }
    }

    private func conflictClone(_ source: VaultEntry, isRemote: Bool) -> VaultEntry {
        let updatedBy = source.updatedBy.isEmpty ? Self.legacyUpdater : source.updatedBy
        let baseVersion = source.version.isEmpty ? 1 : source.version[updatedBy] ?? 1
        return VaultEntry(
            id: idGenerator(),
            label: "\(source.label) \(conflictLabelBuilder(source, isRemote))",
            type: source.type,
            payload: source.payload,
            customFields: source.customFields,
            createdAt: now(),
            updatedAt: source.updatedAt,
            isDeleted: source.isDeleted,
            deletedAt: source.deletedAt,
            version: [updatedBy: baseVersion],
            updatedBy: updatedBy
        )
    }

    private static let legacyUpdater = "legacy"
}
