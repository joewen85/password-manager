package life.devops.passwordmanager.sync

import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CategorySyncState
import life.devops.passwordmanager.model.SecuritySettings
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultSnapshot
import life.devops.passwordmanager.store.VaultJson
import life.devops.passwordmanager.store.withCategory
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

data class VaultSyncPayload(
    val version: Int = 1,
    val exportedAt: Instant,
    val deviceId: String,
    val revision: Int,
    val snapshot: VaultSnapshot,
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("version", version)
            .put("exportedAt", exportedAt.toString())
            .put("deviceId", deviceId)
            .put("revision", revision)
            .put("snapshot", JSONObject(VaultJson.encodeSnapshot(snapshot)))

    companion object {
        fun fromJson(raw: String): VaultSyncPayload {
            val json = JSONObject(raw)
            return VaultSyncPayload(
                version = json.optInt("version", 1),
                exportedAt = json.optionalInstant("exportedAt") ?: Instant.EPOCH,
                deviceId = json.optString("deviceId"),
                revision = json.optInt("revision", 0),
                snapshot = VaultJson.decodeSnapshot(json.getJSONObject("snapshot").toString()),
            )
        }
    }
}

data class VaultSyncEngineResult(
    val snapshot: VaultSnapshot,
    val settings: SyncSettings,
    val stats: SyncMergeStats,
    val uploaded: Boolean,
    val appliedRemote: Boolean,
)

class VaultSyncEngineException(message: String) : Exception(message)
class VaultSyncCancelledException : Exception("Sync was cancelled because local data changed.")

class VaultSyncEngine(
    private val clock: () -> Instant = { Instant.now() },
    private val idGenerator: () -> String = { UUID.randomUUID().toString() },
) {
    fun synchronize(
        localSnapshot: VaultSnapshot,
        settings: SyncSettings,
        client: RemoteSyncClient,
        shouldCancelUpload: () -> Boolean = { false },
    ): VaultSyncEngineResult {
        val hasSyncBaseline = hasEstablishedSyncBaseline(settings)
        val remoteMetadata = client.metadata()
        val remoteFingerprint = remoteMetadata.fingerprint
        if (
            !settings.hasLocalChanges &&
            remoteFingerprint != null &&
            remoteFingerprint == settings.lastRemoteFingerprint &&
            isSuccessfulDownload(remoteMetadata.statusCode)
        ) {
            return noChangeResult(localSnapshot, settings, remoteFingerprint)
        }

        val download = client.download()
        if (!isSuccessfulDownload(download.statusCode)) {
            throw VaultSyncEngineException("Sync download failed with status ${download.statusCode}.")
        }

        val localPayload = VaultSyncPayload(
            exportedAt = clock(),
            deviceId = settings.deviceId,
            revision = settings.lastSyncRevision,
            snapshot = localSnapshot,
        )
        val remotePayload = decodePayload(download.payload)
        if (remotePayload == null) {
            upload(localPayload, client, shouldCancelUpload)
            return result(
                snapshot = localSnapshot,
                settings = settings,
                revision = localPayload.revision,
                stats = SyncMergeStats(
                    total = localSnapshot.entries.size,
                    conflicts = 0,
                    deletes = localSnapshot.entries.count { it.isDeleted },
                ),
                uploaded = true,
                appliedRemote = false,
                remoteFingerprint = remoteFingerprint,
            )
        }

        if (
            hasSyncBaseline &&
            settings.hasLocalChanges &&
            remotePayload.revision <= settings.lastSyncRevision
        ) {
            val nextRevision = settings.lastSyncRevision + 1
            val uploadPayload = localPayload.copy(revision = nextRevision)
            upload(uploadPayload, client, shouldCancelUpload)
            return result(
                snapshot = localSnapshot,
                settings = settings,
                revision = nextRevision,
                stats = SyncMergeStats(
                    total = localSnapshot.entries.size,
                    conflicts = 0,
                    deletes = localSnapshot.entries.count { it.isDeleted },
                ),
                uploaded = true,
                appliedRemote = false,
                remoteFingerprint = null,
            )
        }

        val merger = VaultSyncMerger(
            idGenerator = idGenerator,
            conflictLabelBuilder = { entry, isRemote ->
                val source = if (isRemote) "remote" else "local"
                val who = entry.updatedBy.ifBlank { "unknown" }
                "(conflict-$source-$who)"
            },
            conflictStrategy = settings.conflictStrategy.mergeStrategy,
            clock = clock,
        )
        val mergeResult = merger.merge(
            localEntries = localSnapshot.entries,
            remoteEntries = remotePayload.snapshot.entries,
        )
        val mergedSnapshot = mergeSnapshot(
            local = localSnapshot,
            remote = remotePayload.snapshot,
            entries = mergeResult.entries,
            hasSyncBaseline = hasSyncBaseline,
            localHasChanges = settings.hasLocalChanges,
            conflictStrategy = settings.conflictStrategy,
            localDeviceId = settings.deviceId,
            remoteDeviceId = remotePayload.deviceId,
        )

        if (hasSameSyncBusinessContent(mergedSnapshot, remotePayload.snapshot)) {
            return result(
                snapshot = mergedSnapshot,
                settings = settings,
                revision = remotePayload.revision,
                stats = mergeResult.stats,
                uploaded = false,
                appliedRemote = mergedSnapshot != localSnapshot,
                remoteFingerprint = remoteFingerprint,
            )
        }

        val mergedRevision = maxOf(localPayload.revision, remotePayload.revision) + 1
        upload(
            VaultSyncPayload(
                exportedAt = clock(),
                deviceId = settings.deviceId,
                revision = mergedRevision,
                snapshot = mergedSnapshot,
            ),
            client,
            shouldCancelUpload,
        )
        return result(
            snapshot = mergedSnapshot,
            settings = settings,
            revision = mergedRevision,
            stats = mergeResult.stats,
            uploaded = true,
            appliedRemote = mergedSnapshot != localSnapshot,
            remoteFingerprint = null,
        )
    }

    fun encodePayload(payload: VaultSyncPayload): String =
        payload.toJson().toString()

    fun decodePayload(rawPayload: String?): VaultSyncPayload? {
        val raw = rawPayload?.trim()
        if (raw.isNullOrEmpty()) return null
        return runCatching { VaultSyncPayload.fromJson(raw) }
            .getOrElse { throw VaultSyncEngineException("Remote sync payload is invalid.") }
    }

    private fun upload(
        payload: VaultSyncPayload,
        client: RemoteSyncClient,
        shouldCancelUpload: () -> Boolean,
    ) {
        if (shouldCancelUpload()) {
            throw VaultSyncCancelledException()
        }
        val upload = client.upload(encodePayload(payload))
        if (upload.statusCode !in 200..299) {
            throw VaultSyncEngineException("Sync upload failed with status ${upload.statusCode}.")
        }
    }

    private fun mergeSnapshot(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        entries: List<VaultEntry>,
        hasSyncBaseline: Boolean,
        localHasChanges: Boolean,
        conflictStrategy: SyncSettingsConflictStrategy,
        localDeviceId: String,
        remoteDeviceId: String,
    ): VaultSnapshot {
        val latestSnapshot = if (local.updatedAt >= remote.updatedAt) local else remote
        val categoryStates = mergeCategoryStates(
            local = local,
            remote = remote,
            hasSyncBaseline = hasSyncBaseline,
            localHasChanges = localHasChanges,
            conflictStrategy = conflictStrategy,
            localDeviceId = localDeviceId,
            remoteDeviceId = remoteDeviceId,
        )
        val deletedCategoryKeys = categoryStates
            .filter { it.isDeleted }
            .map { normalizedCategoryKey(it.name) }
            .toSet()
        val normalizedEntries = clearDeletedCategoryReferences(
            entries = entries,
            deletedCategoryKeys = deletedCategoryKeys,
            deviceId = localDeviceId,
        )
        val activeEntries = normalizedEntries.filterNot { it.isDeleted }
        val shouldMergeCleanLocalTaxonomy = conflictStrategy == SyncSettingsConflictStrategy.KEEP_BOTH && !localHasChanges
        val baseCategoryTemplates = if (shouldMergeCleanLocalTaxonomy) {
            remote.categoryTemplates + local.categoryTemplates
        } else if (localHasChanges) {
            local.categoryTemplates
        } else {
            remote.categoryTemplates
        }
        val categories = mergeTaxonomy(
            base = categoryStates.filterNot { it.isDeleted }.map { it.name },
            entries = activeEntries.map { it.payload.category } + baseCategoryTemplates.map { it.category },
        ).filterNot { normalizedCategoryKey(it) in deletedCategoryKeys }
        val baseTags = if (shouldMergeCleanLocalTaxonomy) {
            local.tags + remote.tags
        } else if (localHasChanges) {
            local.tags
        } else {
            remote.tags
        }
        val tags = mergeTaxonomy(
            base = baseTags,
            entries = activeEntries.flatMap { it.payload.tags },
        )
        val categoryTemplates = mergeCategoryTemplates(
            base = baseCategoryTemplates,
            local = local.categoryTemplates,
            remote = remote.categoryTemplates,
            categories = categories,
        )
        return VaultSnapshot(
            entries = normalizedEntries.sortedByDescending { it.updatedAt },
            categories = categories,
            categoryTemplates = categoryTemplates,
            categoryStates = categoryStates,
            tags = tags,
            security = latestSnapshot.security.takeUnless { it == SecuritySettings() } ?: local.security,
            syncStatus = latestSnapshot.syncStatus,
            backupStatus = latestSnapshot.backupStatus,
            updatedAt = maxOf(local.updatedAt, remote.updatedAt),
        )
    }

    private fun mergeCategoryStates(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        hasSyncBaseline: Boolean,
        localHasChanges: Boolean,
        conflictStrategy: SyncSettingsConflictStrategy,
        localDeviceId: String,
        remoteDeviceId: String,
    ): List<CategorySyncState> {
        val localStates = effectiveCategoryStates(local).toMutableMap()
        val remoteStates = effectiveCategoryStates(remote).toMutableMap()

        if (hasSyncBaseline && localHasChanges) {
            remoteStates.forEach { (key, remoteState) ->
                if (key !in localStates && !remoteState.isDeleted) {
                    localStates[key] = categoryTombstone(
                        state = remoteState,
                        deviceId = localDeviceId,
                        updatedAt = local.updatedAt,
                    )
                }
            }
        } else if (hasSyncBaseline && conflictStrategy == SyncSettingsConflictStrategy.REMOTE_WINS) {
            localStates.forEach { (key, localState) ->
                if (key !in remoteStates && !localState.isDeleted) {
                    remoteStates[key] = categoryTombstone(
                        state = localState,
                        deviceId = remoteDeviceId,
                        updatedAt = remote.updatedAt,
                    )
                }
            }
        }

        return (localStates.keys + remoteStates.keys).mapNotNull { key ->
            val localState = localStates[key]
            val remoteState = remoteStates[key]
            when {
                localState != null && remoteState != null -> resolveCategoryState(
                    local = localState,
                    remote = remoteState,
                    conflictStrategy = conflictStrategy,
                )
                localState != null -> localState
                else -> remoteState
            }
        }.sortedBy { it.name.lowercase() }
    }

    private fun hasEstablishedSyncBaseline(settings: SyncSettings): Boolean =
        settings.lastSyncRevision > 0 ||
            !settings.lastRemoteFingerprint.isNullOrBlank() ||
            (settings.lastSyncAt != null && settings.lastSyncStatus == "success")

    private fun effectiveCategoryStates(snapshot: VaultSnapshot): Map<String, CategorySyncState> {
        val states = linkedMapOf<String, CategorySyncState>()
        snapshot.categoryStates.forEach { rawState ->
            val name = rawState.name.trim()
            if (name.isBlank()) return@forEach
            val updater = rawState.updatedBy.ifBlank { "legacy" }
            val state = rawState.copy(
                name = name,
                version = rawState.version.ifEmpty { mapOf(updater to 1) },
                updatedBy = updater,
            )
            val key = normalizedCategoryKey(name)
            states[key] = states[key]?.let { existing ->
                resolveCategoryState(existing, state, SyncSettingsConflictStrategy.KEEP_BOTH)
            } ?: state
        }
        val legacyNames = snapshot.categories +
            snapshot.categoryTemplates.map { it.category } +
            snapshot.entries.filterNot { it.isDeleted }.map { it.payload.category }
        legacyNames.forEach { rawName ->
            val name = rawName.trim()
            val key = normalizedCategoryKey(name)
            if (name.isNotBlank() && key !in states) {
                states[key] = CategorySyncState(
                    name = name,
                    updatedAt = snapshot.updatedAt,
                    version = mapOf("legacy" to 1),
                    updatedBy = "legacy",
                )
            }
        }
        return states
    }

    private fun resolveCategoryState(
        local: CategorySyncState,
        remote: CategorySyncState,
        conflictStrategy: SyncSettingsConflictStrategy,
    ): CategorySyncState =
        when (VaultSyncMerger.compareVersion(local.version, remote.version)) {
            VersionComparison.LOCAL_DOMINATES -> local
            VersionComparison.REMOTE_DOMINATES -> remote
            VersionComparison.EQUAL,
            VersionComparison.CONCURRENT,
            -> {
                val selected = when {
                    local.isDeleted != remote.isDeleted -> if (local.isDeleted) local else remote
                    conflictStrategy == SyncSettingsConflictStrategy.LOCAL_WINS -> local
                    conflictStrategy == SyncSettingsConflictStrategy.REMOTE_WINS -> remote
                    local.updatedAt >= remote.updatedAt -> local
                    else -> remote
                }
                selected.copy(
                    updatedAt = maxOf(local.updatedAt, remote.updatedAt),
                    version = mergedVersion(local.version, remote.version),
                )
            }
        }

    private fun categoryTombstone(
        state: CategorySyncState,
        deviceId: String,
        updatedAt: Instant,
    ): CategorySyncState {
        val updater = deviceId.trim().ifBlank { "legacy" }
        val version = state.version.toMutableMap()
        version[updater] = (version[updater] ?: 0) + 1
        return state.copy(
            isDeleted = true,
            updatedAt = updatedAt,
            version = version,
            updatedBy = updater,
        )
    }

    private fun clearDeletedCategoryReferences(
        entries: List<VaultEntry>,
        deletedCategoryKeys: Set<String>,
        deviceId: String,
    ): List<VaultEntry> {
        val updater = deviceId.trim().ifBlank { "android-native" }
        return entries.map { entry ->
            if (entry.isDeleted || normalizedCategoryKey(entry.payload.category) !in deletedCategoryKeys) {
                entry
            } else {
                val version = entry.version.toMutableMap()
                version[updater] = (version[updater] ?: 0) + 1
                entry.copy(
                    payload = entry.payload.withCategory(""),
                    updatedAt = clock(),
                    version = version,
                    updatedBy = updater,
                )
            }
        }
    }

    private fun mergedVersion(local: Map<String, Int>, remote: Map<String, Int>): Map<String, Int> =
        (local.keys + remote.keys).associateWith { key ->
            maxOf(local[key] ?: 0, remote[key] ?: 0)
        }

    private fun normalizedCategoryKey(category: String): String = category.trim().lowercase()

    private fun mergeTaxonomy(base: List<String>, entries: List<String>): List<String> =
        (base + entries)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toSet()
            .sorted()

    private fun mergeCategoryTemplates(
        base: List<CategoryTemplate>,
        local: List<CategoryTemplate>,
        remote: List<CategoryTemplate>,
        categories: List<String>,
    ): List<CategoryTemplate> {
        val categoryKeys = categories.map { it.trim().lowercase() }.toSet()
        val templatesByCategory = linkedMapOf<String, CategoryTemplate>()

        fun insert(template: CategoryTemplate) {
            val category = template.category.trim()
            val key = category.lowercase()
            if (category.isNotEmpty() && key in categoryKeys && key !in templatesByCategory) {
                templatesByCategory[key] = template.copy(category = category)
            }
        }

        base.forEach(::insert)
        local.forEach(::insert)
        remote.forEach(::insert)

        return categories.mapNotNull { category ->
            val key = category.trim().lowercase()
            templatesByCategory[key]
        }
    }

    private fun result(
        snapshot: VaultSnapshot,
        settings: SyncSettings,
        revision: Int,
        stats: SyncMergeStats,
        uploaded: Boolean,
        appliedRemote: Boolean,
        remoteFingerprint: String?,
    ): VaultSyncEngineResult {
        val message = "Synced ${stats.total} items, ${stats.conflicts} conflicts, ${stats.deletes} deletes, revision $revision."
        val updatedSettings = settings.copy(
            lastSyncRevision = revision,
            lastSyncAt = clock(),
            lastSyncStatus = "success",
            lastSyncMessage = message,
            lastRemoteFingerprint = remoteFingerprint,
            logs = (listOf(SyncLogEntry(timestamp = clock(), message = message, level = "info")) + settings.logs).take(50),
        )
        return VaultSyncEngineResult(
            snapshot = snapshot,
            settings = updatedSettings,
            stats = stats,
            uploaded = uploaded,
            appliedRemote = appliedRemote,
        )
    }

    private fun noChangeResult(
        snapshot: VaultSnapshot,
        settings: SyncSettings,
        remoteFingerprint: String,
    ): VaultSyncEngineResult {
        val message = "Remote unchanged; skipped full sync download."
        val updatedSettings = settings.copy(
            lastSyncAt = clock(),
            lastSyncStatus = "success",
            lastSyncMessage = message,
            lastRemoteFingerprint = remoteFingerprint,
            logs = (listOf(SyncLogEntry(timestamp = clock(), message = message, level = "info")) + settings.logs).take(50),
        )
        return VaultSyncEngineResult(
            snapshot = snapshot,
            settings = updatedSettings,
            stats = SyncMergeStats(total = snapshot.entries.size, conflicts = 0, deletes = snapshot.entries.count { it.isDeleted }),
            uploaded = false,
            appliedRemote = false,
        )
    }

    private fun hasSameSyncBusinessContent(left: VaultSnapshot, right: VaultSnapshot): Boolean =
        left.entries == right.entries &&
            left.categories == right.categories &&
            left.categoryTemplates == right.categoryTemplates &&
            left.categoryStates == right.categoryStates &&
            left.tags == right.tags &&
            left.security == right.security

    private fun isSuccessfulDownload(statusCode: Int): Boolean =
        statusCode in 200..299 || statusCode == 404
}

private fun JSONObject.optionalInstant(name: String): Instant? {
    if (!has(name) || isNull(name)) return null
    val value = optString(name).takeIf { it.isNotBlank() } ?: return null
    return runCatching { Instant.parse(value) }.getOrNull()
}
