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
    NAS_WEBDAV,
    TENCENT_COS,
    ALIYUN_OSS;

    val wireName: String
        get() = when (this) {
            NONE -> "none"
            WEBDAV -> "webdav"
            S3_PRESIGNED -> "s3Presigned"
            NAS_WEBDAV -> "nasWebdav"
            TENCENT_COS -> "tencentCos"
            ALIYUN_OSS -> "aliyunOss"
        }

    val title: String
        get() = when (this) {
            NONE -> "None"
            WEBDAV -> "WebDAV"
            S3_PRESIGNED -> "S3 Presigned URL"
            NAS_WEBDAV -> "NAS WebDAV"
            TENCENT_COS -> "Tencent Cloud COS"
            ALIYUN_OSS -> "Alibaba Cloud OSS"
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

enum class SyncIntervalUnit {
    SECONDS,
    MINUTES;

    val wireName: String
        get() = when (this) {
            SECONDS -> "seconds"
            MINUTES -> "minutes"
        }

    companion object {
        fun fromWireName(value: String?): SyncIntervalUnit =
            entries.firstOrNull { it.wireName == value } ?: MINUTES
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
    val objectStorageAccessKeyId: String,
    val objectStorageSecretAccessKey: String,
    val objectStorageBucket: String,
    val objectStorageEndpoint: String,
    val objectStorageAppId: String,
    val objectStorageCustomUrl: String,
    val objectStorageObjectKey: String,
    val autoSyncEnabled: Boolean,
    val autoSyncIntervalMinutes: Int,
    val autoSyncIntervalValue: Int,
    val autoSyncIntervalUnit: SyncIntervalUnit,
    val autoSyncOnUnlock: Boolean,
    val conflictStrategy: SyncSettingsConflictStrategy,
    val syncMasterKey: Boolean,
    val deviceId: String,
    val lastSyncRevision: Int,
    val lastSyncAt: Instant?,
    val lastSyncStatus: String?,
    val lastSyncMessage: String?,
    val lastRemoteFingerprint: String?,
    val hasLocalChanges: Boolean,
    val logs: List<SyncLogEntry>,
) {
    val syncSecrets: SyncSecretBundle
        get() = SyncSecretBundle(
            webdavPassword = webdavPassword,
            presignedDownloadUrl = presignedDownloadUrl,
            presignedUploadUrl = presignedUploadUrl,
            objectStorageAccessKeyId = objectStorageAccessKeyId,
            objectStorageSecretAccessKey = objectStorageSecretAccessKey,
        )

    fun redactedForPlaintextStorage(): SyncSettings =
        applyingSecrets(SyncSecretBundle.EMPTY)

    fun applyingSecrets(secrets: SyncSecretBundle): SyncSettings =
        copy(
            webdavPassword = secrets.webdavPassword,
            presignedDownloadUrl = secrets.presignedDownloadUrl,
            presignedUploadUrl = secrets.presignedUploadUrl,
            objectStorageAccessKeyId = secrets.objectStorageAccessKeyId,
            objectStorageSecretAccessKey = secrets.objectStorageSecretAccessKey,
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
            .put("objectStorageAccessKeyId", objectStorageAccessKeyId)
            .put("objectStorageSecretAccessKey", objectStorageSecretAccessKey)
            .put("objectStorageBucket", objectStorageBucket)
            .put("objectStorageEndpoint", objectStorageEndpoint)
            .put("objectStorageAppId", objectStorageAppId)
            .put("objectStorageCustomUrl", objectStorageCustomUrl)
            .put("objectStorageObjectKey", objectStorageObjectKey)
            .put("autoSyncEnabled", autoSyncEnabled)
            .put("autoSyncIntervalMinutes", autoSyncIntervalMinutes)
            .put("autoSyncIntervalValue", autoSyncIntervalValue)
            .put("autoSyncIntervalUnit", autoSyncIntervalUnit.wireName)
            .put("autoSyncOnUnlock", autoSyncOnUnlock)
            .put("conflictStrategy", conflictStrategy.wireName)
            .put("syncMasterKey", syncMasterKey)
            .put("deviceId", deviceId)
            .put("lastSyncRevision", lastSyncRevision)
            .put("lastSyncAt", lastSyncAt?.toString())
            .put("lastSyncStatus", lastSyncStatus)
            .put("lastSyncMessage", lastSyncMessage)
            .put("lastRemoteFingerprint", lastRemoteFingerprint)
            .put("hasLocalChanges", hasLocalChanges)
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
                objectStorageAccessKeyId = "",
                objectStorageSecretAccessKey = "",
                objectStorageBucket = "",
                objectStorageEndpoint = "",
                objectStorageAppId = "",
                objectStorageCustomUrl = "",
                objectStorageObjectKey = "vault.sync.json",
                autoSyncEnabled = false,
                autoSyncIntervalMinutes = 30,
                autoSyncIntervalValue = 30,
                autoSyncIntervalUnit = SyncIntervalUnit.MINUTES,
                autoSyncOnUnlock = true,
                conflictStrategy = SyncSettingsConflictStrategy.REMOTE_WINS,
                syncMasterKey = true,
                deviceId = deviceId,
                lastSyncRevision = 0,
                lastSyncAt = null,
                lastSyncStatus = null,
                lastSyncMessage = null,
                lastRemoteFingerprint = null,
                hasLocalChanges = false,
                logs = emptyList(),
            )

        fun fromJson(json: JSONObject): SyncSettings {
            val defaults = defaults(deviceId = "")
            val intervalUnit = SyncIntervalUnit.fromWireName(json.optionalString("autoSyncIntervalUnit"))
            val intervalValue = if (json.has("autoSyncIntervalValue") && !json.isNull("autoSyncIntervalValue")) {
                json.optInt("autoSyncIntervalValue", defaults.autoSyncIntervalValue)
            } else {
                json.optInt("autoSyncIntervalMinutes", defaults.autoSyncIntervalMinutes)
            }.coerceAtLeast(1)
            val intervalMinutes = if (json.has("autoSyncIntervalMinutes") && !json.isNull("autoSyncIntervalMinutes")) {
                json.optInt("autoSyncIntervalMinutes", defaults.autoSyncIntervalMinutes)
            } else {
                intervalValue.toIntervalMinutes(intervalUnit)
            }.coerceAtLeast(1)
            return SyncSettings(
                providerType = SyncProviderType.fromWireName(json.optionalString("providerType")),
                webdavUrl = json.optString("webdavUrl", defaults.webdavUrl),
                webdavUsername = json.optString("webdavUsername", defaults.webdavUsername),
                webdavPassword = json.optString("webdavPassword", defaults.webdavPassword),
                webdavPath = json.optString("webdavPath", defaults.webdavPath),
                presignedDownloadUrl = json.optString("presignedDownloadUrl", defaults.presignedDownloadUrl),
                presignedUploadUrl = json.optString("presignedUploadUrl", defaults.presignedUploadUrl),
                objectStorageAccessKeyId = json.optString("objectStorageAccessKeyId", defaults.objectStorageAccessKeyId),
                objectStorageSecretAccessKey = json.optString("objectStorageSecretAccessKey", defaults.objectStorageSecretAccessKey),
                objectStorageBucket = json.optString("objectStorageBucket", defaults.objectStorageBucket),
                objectStorageEndpoint = json.optString("objectStorageEndpoint", defaults.objectStorageEndpoint),
                objectStorageAppId = json.optString("objectStorageAppId", defaults.objectStorageAppId),
                objectStorageCustomUrl = json.optString("objectStorageCustomUrl", defaults.objectStorageCustomUrl),
                objectStorageObjectKey = json.optString("objectStorageObjectKey", defaults.objectStorageObjectKey),
                autoSyncEnabled = json.optBoolean("autoSyncEnabled", defaults.autoSyncEnabled),
                autoSyncIntervalMinutes = intervalMinutes,
                autoSyncIntervalValue = intervalValue,
                autoSyncIntervalUnit = intervalUnit,
                autoSyncOnUnlock = json.optBoolean("autoSyncOnUnlock", defaults.autoSyncOnUnlock),
                conflictStrategy = SyncSettingsConflictStrategy.fromWireName(json.optionalString("conflictStrategy")),
                syncMasterKey = json.optBoolean("syncMasterKey", defaults.syncMasterKey),
                deviceId = json.optString("deviceId", defaults.deviceId),
                lastSyncRevision = json.optInt("lastSyncRevision", defaults.lastSyncRevision),
                lastSyncAt = json.optionalString("lastSyncAt")?.let(Instant::parse),
                lastSyncStatus = json.optionalString("lastSyncStatus"),
                lastSyncMessage = json.optionalString("lastSyncMessage"),
                lastRemoteFingerprint = json.optionalString("lastRemoteFingerprint"),
                hasLocalChanges = json.optBoolean("hasLocalChanges", defaults.hasLocalChanges),
                logs = json.optJSONArray("logs")?.toSyncLogs().orEmpty(),
            )
        }

        fun generateDeviceId(): String =
            "${Instant.now().toEpochMilli() * 1000}-${UUID.randomUUID().toString().take(8).lowercase(Locale.US)}"
    }
}

fun Int.toIntervalMinutes(unit: SyncIntervalUnit): Int =
    when (unit) {
        SyncIntervalUnit.SECONDS -> ((this.coerceAtLeast(1) + 59) / 60).coerceAtLeast(1)
        SyncIntervalUnit.MINUTES -> coerceAtLeast(1)
    }

data class SyncSecretBundle(
    val webdavPassword: String = "",
    val presignedDownloadUrl: String = "",
    val presignedUploadUrl: String = "",
    val objectStorageAccessKeyId: String = "",
    val objectStorageSecretAccessKey: String = "",
) {
    val isEmpty: Boolean
        get() = webdavPassword.isEmpty() &&
            presignedDownloadUrl.isEmpty() &&
            presignedUploadUrl.isEmpty() &&
            objectStorageAccessKeyId.isEmpty() &&
            objectStorageSecretAccessKey.isEmpty()

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
            SyncProviderType.TENCENT_COS,
            SyncProviderType.ALIYUN_OSS -> {
                if (
                    settings.objectStorageAccessKeyId.isBlank() ||
                    settings.objectStorageSecretAccessKey.isBlank() ||
                    settings.objectStorageBucket.isBlank() ||
                    (settings.objectStorageEndpoint.isBlank() && settings.objectStorageCustomUrl.isBlank())
                ) {
                    null
                } else {
                    ObjectStorageSyncClient(
                        providerType = settings.providerType,
                        accessKeyId = settings.objectStorageAccessKeyId.trim(),
                        secretAccessKey = settings.objectStorageSecretAccessKey.trim(),
                        bucket = settings.objectStorageBucket.trim(),
                        endpoint = settings.objectStorageEndpoint.trim(),
                        appId = settings.objectStorageAppId.trim(),
                        customUrl = settings.objectStorageCustomUrl.trim(),
                        objectKey = settings.objectStorageObjectKey.trim().ifBlank { "vault.sync.json" },
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
