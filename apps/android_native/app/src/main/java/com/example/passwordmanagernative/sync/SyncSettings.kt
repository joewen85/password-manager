package com.example.passwordmanagernative.sync

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.Locale
import java.util.UUID

enum class SyncProviderType {
    NONE,
    WEBDAV,
    S3_PRESIGNED,
    NAS_WEBDAV;

    val wireName: String
        get() = when (this) {
            NONE -> "none"
            WEBDAV -> "webdav"
            S3_PRESIGNED -> "s3Presigned"
            NAS_WEBDAV -> "nasWebdav"
        }

    val title: String
        get() = when (this) {
            NONE -> "None"
            WEBDAV -> "WebDAV"
            S3_PRESIGNED -> "S3 Presigned URL"
            NAS_WEBDAV -> "NAS WebDAV"
        }

    companion object {
        fun fromWireName(value: String?): SyncProviderType =
            entries.firstOrNull { it.wireName == value } ?: NONE
    }
}

enum class SyncSettingsConflictStrategy {
    REMOTE_WINS,
    LOCAL_WINS,
    KEEP_BOTH;

    val wireName: String
        get() = when (this) {
            REMOTE_WINS -> "remoteWins"
            LOCAL_WINS -> "localWins"
            KEEP_BOTH -> "keepBoth"
        }

    val title: String
        get() = when (this) {
            REMOTE_WINS -> "Remote Wins"
            LOCAL_WINS -> "Local Wins"
            KEEP_BOTH -> "Keep Both"
        }

    val mergeStrategy: SyncConflictStrategy
        get() = when (this) {
            REMOTE_WINS -> SyncConflictStrategy.REMOTE_WINS
            LOCAL_WINS -> SyncConflictStrategy.LOCAL_WINS
            KEEP_BOTH -> SyncConflictStrategy.KEEP_BOTH
        }

    companion object {
        fun fromWireName(value: String?): SyncSettingsConflictStrategy =
            entries.firstOrNull { it.wireName == value } ?: REMOTE_WINS
    }
}

data class SyncLogEntry(
    val timestamp: Instant,
    val message: String,
    val level: String,
)

data class SyncSettings(
    val providerType: SyncProviderType,
    val webdavUrl: String,
    val webdavUsername: String,
    val webdavPassword: String,
    val webdavPath: String,
    val presignedDownloadUrl: String,
    val presignedUploadUrl: String,
    val autoSyncEnabled: Boolean,
    val autoSyncIntervalMinutes: Int,
    val autoSyncOnUnlock: Boolean,
    val conflictStrategy: SyncSettingsConflictStrategy,
    val syncMasterKey: Boolean,
    val deviceId: String,
    val lastSyncRevision: Int,
    val lastSyncAt: Instant?,
    val lastSyncStatus: String?,
    val lastSyncMessage: String?,
    val logs: List<SyncLogEntry>,
) {
    val syncSecrets: SyncSecretBundle
        get() = SyncSecretBundle(
            webdavPassword = webdavPassword,
            presignedDownloadUrl = presignedDownloadUrl,
            presignedUploadUrl = presignedUploadUrl,
        )

    fun redactedForPlaintextStorage(): SyncSettings =
        applyingSecrets(SyncSecretBundle.EMPTY)

    fun applyingSecrets(secrets: SyncSecretBundle): SyncSettings =
        copy(
            webdavPassword = secrets.webdavPassword,
            presignedDownloadUrl = secrets.presignedDownloadUrl,
            presignedUploadUrl = secrets.presignedUploadUrl,
        )

    fun toJson(): JSONObject =
        JSONObject()
            .put("providerType", providerType.wireName)
            .put("webdavUrl", webdavUrl)
            .put("webdavUsername", webdavUsername)
            .put("webdavPassword", webdavPassword)
            .put("webdavPath", webdavPath)
            .put("presignedDownloadUrl", presignedDownloadUrl)
            .put("presignedUploadUrl", presignedUploadUrl)
            .put("autoSyncEnabled", autoSyncEnabled)
            .put("autoSyncIntervalMinutes", autoSyncIntervalMinutes)
            .put("autoSyncOnUnlock", autoSyncOnUnlock)
            .put("conflictStrategy", conflictStrategy.wireName)
            .put("syncMasterKey", syncMasterKey)
            .put("deviceId", deviceId)
            .put("lastSyncRevision", lastSyncRevision)
            .put("lastSyncAt", lastSyncAt?.toString())
            .put("lastSyncStatus", lastSyncStatus)
            .put("lastSyncMessage", lastSyncMessage)
            .put(
                "logs",
                JSONArray(
                    logs.map { entry ->
                        JSONObject()
                            .put("timestamp", entry.timestamp.toString())
                            .put("message", entry.message)
                            .put("level", entry.level)
                    }
                )
            )

    companion object {
        fun defaults(deviceId: String = generateDeviceId()): SyncSettings =
            SyncSettings(
                providerType = SyncProviderType.NONE,
                webdavUrl = "",
                webdavUsername = "",
                webdavPassword = "",
                webdavPath = "/vault.json",
                presignedDownloadUrl = "",
                presignedUploadUrl = "",
                autoSyncEnabled = false,
                autoSyncIntervalMinutes = 30,
                autoSyncOnUnlock = true,
                conflictStrategy = SyncSettingsConflictStrategy.REMOTE_WINS,
                syncMasterKey = true,
                deviceId = deviceId,
                lastSyncRevision = 0,
                lastSyncAt = null,
                lastSyncStatus = null,
                lastSyncMessage = null,
                logs = emptyList(),
            )

        fun fromJson(json: JSONObject): SyncSettings {
            val defaults = defaults(deviceId = "")
            return SyncSettings(
                providerType = SyncProviderType.fromWireName(json.optionalString("providerType")),
                webdavUrl = json.optString("webdavUrl", defaults.webdavUrl),
                webdavUsername = json.optString("webdavUsername", defaults.webdavUsername),
                webdavPassword = json.optString("webdavPassword", defaults.webdavPassword),
                webdavPath = json.optString("webdavPath", defaults.webdavPath),
                presignedDownloadUrl = json.optString("presignedDownloadUrl", defaults.presignedDownloadUrl),
                presignedUploadUrl = json.optString("presignedUploadUrl", defaults.presignedUploadUrl),
                autoSyncEnabled = json.optBoolean("autoSyncEnabled", defaults.autoSyncEnabled),
                autoSyncIntervalMinutes = json.optInt("autoSyncIntervalMinutes", defaults.autoSyncIntervalMinutes),
                autoSyncOnUnlock = json.optBoolean("autoSyncOnUnlock", defaults.autoSyncOnUnlock),
                conflictStrategy = SyncSettingsConflictStrategy.fromWireName(json.optionalString("conflictStrategy")),
                syncMasterKey = json.optBoolean("syncMasterKey", defaults.syncMasterKey),
                deviceId = json.optString("deviceId", defaults.deviceId),
                lastSyncRevision = json.optInt("lastSyncRevision", defaults.lastSyncRevision),
                lastSyncAt = json.optionalString("lastSyncAt")?.let(Instant::parse),
                lastSyncStatus = json.optionalString("lastSyncStatus"),
                lastSyncMessage = json.optionalString("lastSyncMessage"),
                logs = json.optJSONArray("logs")?.toSyncLogs().orEmpty(),
            )
        }

        fun generateDeviceId(): String =
            "${Instant.now().toEpochMilli() * 1000}-${UUID.randomUUID().toString().take(8).lowercase(Locale.US)}"
    }
}

data class SyncSecretBundle(
    val webdavPassword: String = "",
    val presignedDownloadUrl: String = "",
    val presignedUploadUrl: String = "",
) {
    val isEmpty: Boolean
        get() = webdavPassword.isEmpty() &&
            presignedDownloadUrl.isEmpty() &&
            presignedUploadUrl.isEmpty()

    companion object {
        val EMPTY = SyncSecretBundle()
    }
}

class SyncClientFactory {
    fun makeClient(
        settings: SyncSettings,
        transport: RemoteSyncHttpTransport = UrlConnectionRemoteSyncTransport(),
    ): RemoteSyncClient? =
        when (settings.providerType) {
            SyncProviderType.NONE -> null
            SyncProviderType.WEBDAV,
            SyncProviderType.NAS_WEBDAV -> {
                if (settings.webdavUrl.isBlank() || settings.webdavPath.isBlank()) {
                    null
                } else {
                    WebDavSyncClient(
                        baseUrl = settings.webdavUrl.trim(),
                        remotePath = settings.webdavPath.trim(),
                        username = settings.webdavUsername.trim(),
                        password = settings.webdavPassword.trim(),
                        transport = transport,
                    )
                }
            }
            SyncProviderType.S3_PRESIGNED -> {
                if (settings.presignedUploadUrl.isBlank()) {
                    null
                } else {
                    PresignedUrlSyncClient(
                        downloadUrl = settings.presignedDownloadUrl.trim(),
                        uploadUrl = settings.presignedUploadUrl.trim(),
                        transport = transport,
                    )
                }
            }
        }
}

private fun JSONArray.toSyncLogs(): List<SyncLogEntry> =
    (0 until length()).mapNotNull { index ->
        val item = optJSONObject(index) ?: return@mapNotNull null
        val timestamp = item.optionalString("timestamp")
            ?.let(Instant::parse)
            ?: Instant.EPOCH
        SyncLogEntry(
            timestamp = timestamp,
            message = item.optString("message", ""),
            level = item.optString("level", "info"),
        )
    }

private fun JSONObject.optionalString(name: String): String? =
    if (has(name) && !isNull(name)) {
        optString(name).takeUnless { it.isBlank() }
    } else {
        null
    }
