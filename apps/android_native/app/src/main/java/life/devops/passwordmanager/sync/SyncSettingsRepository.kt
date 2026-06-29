package life.devops.passwordmanager.sync

import android.content.Context
import org.json.JSONObject
import java.io.File

class SyncSettingsRepository(
    private val settingsFile: File,
    private val secretStore: SyncSecretStore,
) {
    fun load(): SyncSettings {
        val redacted = if (settingsFile.exists()) {
            SyncSettings.fromJson(JSONObject(settingsFile.readText()))
        } else {
            SyncSettings.defaults()
        }
        return redacted.applyingSecrets(secretStore.load(redacted.deviceId))
    }

    fun save(settings: SyncSettings): SyncSettings {
        val normalized = settings.ensureDeviceId()
        secretStore.save(normalized.syncSecrets, normalized.deviceId)
        settingsFile.parentFile?.mkdirs()
        settingsFile.writeText(normalized.redactedForPlaintextStorage().toJson().toString(2))
        return normalized
    }

    fun delete() {
        val existing = load()
        secretStore.delete(existing.deviceId)
        settingsFile.delete()
    }

    fun rawSettingsFile(): String? =
        settingsFile.takeIf { it.exists() }?.readText()

    private fun SyncSettings.ensureDeviceId(): SyncSettings =
        if (deviceId.isBlank()) {
            copy(deviceId = SyncSettings.generateDeviceId())
        } else {
            this
        }

    companion object {
        fun fromContext(context: Context): SyncSettingsRepository {
            val filesDir = context.applicationContext.filesDir
            return SyncSettingsRepository(
                settingsFile = File(filesDir, "sync_settings.json"),
                secretStore = FileSyncSecretStore(
                    file = File(filesDir, "sync_secrets.json"),
                    crypto = AndroidKeystoreSyncSecretCipher(),
                ),
            )
        }
    }
}
