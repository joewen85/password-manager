package com.example.passwordmanagernative.sync

import com.example.passwordmanagernative.model.SecuritySettings
import com.example.passwordmanagernative.model.VaultEntry
import com.example.passwordmanagernative.model.VaultSnapshot
import com.example.passwordmanagernative.store.VaultJson
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

class VaultSyncEngine(
    private val clock: () -> Instant = { Instant.now() },
    private val idGenerator: () -> String = { UUID.randomUUID().toString() },
) {
    fun synchronize(
        localSnapshot: VaultSnapshot,
        settings: SyncSettings,
        client: RemoteSyncClient,
    ): VaultSyncEngineResult {
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
            upload(localPayload, client)
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
        )

        if (mergedSnapshot == remotePayload.snapshot) {
            return result(
                snapshot = mergedSnapshot,
                settings = settings,
                revision = remotePayload.revision,
                stats = mergeResult.stats,
                uploaded = false,
                appliedRemote = mergedSnapshot != localSnapshot,
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
        )
        return result(
            snapshot = mergedSnapshot,
            settings = settings,
            revision = mergedRevision,
            stats = mergeResult.stats,
            uploaded = true,
            appliedRemote = mergedSnapshot != localSnapshot,
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

    private fun upload(payload: VaultSyncPayload, client: RemoteSyncClient) {
        val upload = client.upload(encodePayload(payload))
        if (upload.statusCode !in 200..299) {
            throw VaultSyncEngineException("Sync upload failed with status ${upload.statusCode}.")
        }
    }

    private fun mergeSnapshot(
        local: VaultSnapshot,
        remote: VaultSnapshot,
        entries: List<VaultEntry>,
    ): VaultSnapshot {
        val latestSnapshot = if (local.updatedAt >= remote.updatedAt) local else remote
        return VaultSnapshot(
            entries = entries.sortedByDescending { it.updatedAt },
            categories = (local.categories + remote.categories).toSet().sorted(),
            tags = (local.tags + remote.tags).toSet().sorted(),
            security = latestSnapshot.security.takeUnless { it == SecuritySettings() } ?: local.security,
            syncStatus = latestSnapshot.syncStatus,
            backupStatus = latestSnapshot.backupStatus,
            updatedAt = maxOf(local.updatedAt, remote.updatedAt),
        )
    }

    private fun result(
        snapshot: VaultSnapshot,
        settings: SyncSettings,
        revision: Int,
        stats: SyncMergeStats,
        uploaded: Boolean,
        appliedRemote: Boolean,
    ): VaultSyncEngineResult {
        val message = "Synced ${stats.total} items, ${stats.conflicts} conflicts, ${stats.deletes} deletes, revision $revision."
        val updatedSettings = settings.copy(
            lastSyncRevision = revision,
            lastSyncAt = clock(),
            lastSyncStatus = "success",
            lastSyncMessage = message,
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

    private fun isSuccessfulDownload(statusCode: Int): Boolean =
        statusCode in 200..299 || statusCode == 404
}

private fun JSONObject.optionalInstant(name: String): Instant? {
    if (!has(name) || isNull(name)) return null
    val value = optString(name).takeIf { it.isNotBlank() } ?: return null
    return runCatching { Instant.parse(value) }.getOrNull()
}
