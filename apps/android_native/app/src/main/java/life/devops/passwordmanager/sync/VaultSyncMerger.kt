package life.devops.passwordmanager.sync

import life.devops.passwordmanager.model.VaultEntry
import java.time.Instant
import java.util.Locale
import java.util.UUID

enum class VersionComparison {
    EQUAL,
    LOCAL_DOMINATES,
    REMOTE_DOMINATES,
    CONCURRENT,
}

enum class SyncConflictStrategy {
    LOCAL_WINS,
    REMOTE_WINS,
    KEEP_BOTH,
}

data class SyncMergeStats(
    val total: Int,
    val conflicts: Int,
    val deletes: Int,
)

data class SyncMergeResult(
    val entries: List<VaultEntry>,
    val stats: SyncMergeStats,
)

class VaultSyncMerger(
    private val idGenerator: () -> String = { UUID.randomUUID().toString() },
    private val conflictLabelBuilder: (VaultEntry, Boolean) -> String = { _, _ -> "(conflict)" },
    private val conflictStrategy: SyncConflictStrategy = SyncConflictStrategy.KEEP_BOTH,
    private val clock: () -> Instant = { Instant.now() },
) {
    fun merge(localEntries: List<VaultEntry>, remoteEntries: List<VaultEntry>): SyncMergeResult {
        val merged = mutableListOf<VaultEntry>()
        var conflicts = 0
        var deletes = 0

        fun addEntry(entry: VaultEntry) {
            merged += entry.withCanonicalId()
            if (entry.isDeleted) {
                deletes += 1
            }
        }

        val versionCache = mutableMapOf<String, Map<String, Int>>()
        fun effectiveVersion(entry: VaultEntry): Map<String, Int> {
            if (entry.version.isNotEmpty()) return entry.version
            return versionCache.getOrPut(entry.id) {
                mapOf((entry.updatedBy.ifBlank { LEGACY_UPDATER }) to 1)
            }
        }

        val remoteById = entriesById(remoteEntries, ::effectiveVersion).toMutableMap()
        entriesById(localEntries, ::effectiveVersion).forEach { (id, local) ->
            val remote = remoteById.remove(id)
            if (remote == null) {
                addEntry(local)
                return@forEach
            }

            when (compareVersion(effectiveVersion(local), effectiveVersion(remote))) {
                VersionComparison.EQUAL -> addEntry(pickLatest(local, remote))
                VersionComparison.LOCAL_DOMINATES -> addEntry(local)
                VersionComparison.REMOTE_DOMINATES -> addEntry(remote)
                VersionComparison.CONCURRENT -> {
                    if (local.isDeleted != remote.isDeleted) {
                        conflicts += 1
                        val deleted = if (local.isDeleted) local else remote
                        val active = if (local.isDeleted) remote else local
                        addEntry(deleted)
                        merged += conflictClone(active, isRemote = active === remote)
                    } else if (samePayload(local, remote)) {
                        addEntry(pickLatest(local, remote))
                    } else {
                        conflicts += 1
                        val primary = choosePrimary(local, remote)
                        val secondary = if (primary === local) remote else local
                        merged += primary
                        merged += conflictClone(secondary, isRemote = secondary === remote)
                    }
                }
            }
        }

        remoteById.values.forEach(::addEntry)

        return SyncMergeResult(
            entries = merged,
            stats = SyncMergeStats(
                total = merged.size,
                conflicts = conflicts,
                deletes = deletes,
            ),
        )
    }

    private fun pickLatest(local: VaultEntry, remote: VaultEntry): VaultEntry =
        if (local.updatedAt >= remote.updatedAt) local else remote

    private fun samePayload(local: VaultEntry, remote: VaultEntry): Boolean =
        local.label == remote.label &&
            local.type == remote.type &&
            local.payload == remote.payload &&
            local.customFields == remote.customFields &&
            local.isDeleted == remote.isDeleted

    private fun choosePrimary(local: VaultEntry, remote: VaultEntry): VaultEntry =
        when (conflictStrategy) {
            SyncConflictStrategy.LOCAL_WINS -> local
            SyncConflictStrategy.REMOTE_WINS -> remote
            SyncConflictStrategy.KEEP_BOTH -> pickLatest(local, remote)
        }

    private fun entriesById(
        entries: List<VaultEntry>,
        effectiveVersion: (VaultEntry) -> Map<String, Int>,
    ): Map<String, VaultEntry> {
        val entriesById = mutableMapOf<String, VaultEntry>()
        entries.forEach { entry ->
            val canonicalId = entry.id.canonicalUuidString()
            val canonicalEntry = entry.withCanonicalId(canonicalId)
            val existing = entriesById[canonicalId]
            entriesById[canonicalId] = if (existing == null) {
                canonicalEntry
            } else {
                pickDuplicate(existing, canonicalEntry, effectiveVersion)
            }
        }
        return entriesById
    }

    private fun pickDuplicate(
        existing: VaultEntry,
        candidate: VaultEntry,
        effectiveVersion: (VaultEntry) -> Map<String, Int>,
    ): VaultEntry =
        when (compareVersion(effectiveVersion(existing), effectiveVersion(candidate))) {
            VersionComparison.EQUAL -> pickLatest(existing, candidate)
            VersionComparison.LOCAL_DOMINATES -> existing
            VersionComparison.REMOTE_DOMINATES -> candidate
            VersionComparison.CONCURRENT -> pickLatest(existing, candidate)
        }

    private fun conflictClone(source: VaultEntry, isRemote: Boolean): VaultEntry {
        val updatedBy = source.updatedBy.ifBlank { LEGACY_UPDATER }
        val baseVersion = if (source.version.isNotEmpty()) {
            source.version[updatedBy] ?: 1
        } else {
            1
        }
        return source.copy(
            id = idGenerator(),
            label = "${source.label} ${conflictLabelBuilder(source, isRemote)}",
            createdAt = clock(),
            version = mapOf(updatedBy to baseVersion),
            updatedBy = updatedBy,
        )
    }

    companion object {
        private const val LEGACY_UPDATER = "legacy"

        fun compareVersion(local: Map<String, Int>, remote: Map<String, Int>): VersionComparison {
            var localGreater = false
            var remoteGreater = false
            (local.keys + remote.keys).forEach { key ->
                val localValue = local[key] ?: 0
                val remoteValue = remote[key] ?: 0
                if (localValue > remoteValue) {
                    localGreater = true
                } else if (remoteValue > localValue) {
                    remoteGreater = true
                }
                if (localGreater && remoteGreater) {
                    return VersionComparison.CONCURRENT
                }
            }
            return when {
                !localGreater && !remoteGreater -> VersionComparison.EQUAL
                localGreater -> VersionComparison.LOCAL_DOMINATES
                remoteGreater -> VersionComparison.REMOTE_DOMINATES
                else -> VersionComparison.CONCURRENT
            }
        }
    }
}

private fun VaultEntry.withCanonicalId(id: String = this.id.canonicalUuidString()): VaultEntry =
    if (this.id == id) this else copy(id = id)

private fun String.canonicalUuidString(): String {
    val trimmed = trim()
    if (trimmed.isEmpty()) return trimmed
    return runCatching { UUID.fromString(trimmed).toString() }
        .getOrElse { trimmed.lowercase(Locale.ROOT) }
}
