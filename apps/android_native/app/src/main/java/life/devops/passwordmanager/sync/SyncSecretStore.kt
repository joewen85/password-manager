package life.devops.passwordmanager.sync

import life.devops.passwordmanager.store.AndroidVaultCrypto
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets
import java.time.Instant

interface SyncSecretStore {
    fun load(deviceId: String): SyncSecretBundle
    fun save(secrets: SyncSecretBundle, deviceId: String)
    fun delete(deviceId: String)
}

class FileSyncSecretStore(
    private val file: File,
    private val crypto: SyncSecretCipher,
) : SyncSecretStore {
    override fun load(deviceId: String): SyncSecretBundle {
        val root = readRoot()
        val record = root.optJSONObject(deviceId) ?: return SyncSecretBundle.EMPTY
        return crypto.decrypt(record)
    }

    override fun save(secrets: SyncSecretBundle, deviceId: String) {
        if (secrets.isEmpty) {
            delete(deviceId)
            return
        }
        val root = readRoot()
        root.put(deviceId, crypto.encrypt(secrets))
        file.parentFile?.mkdirs()
        file.writeText(root.toString(2), StandardCharsets.UTF_8)
    }

    override fun delete(deviceId: String) {
        val root = readRoot()
        root.remove(deviceId)
        if (root.length() == 0) {
            file.delete()
        } else {
            file.writeText(root.toString(2), StandardCharsets.UTF_8)
        }
    }

    private fun readRoot(): JSONObject {
        if (!file.exists()) return JSONObject()
        val raw = file.readText().trim()
        return if (raw.isEmpty()) JSONObject() else JSONObject(raw)
    }
}

interface SyncSecretCipher {
    fun encrypt(secrets: SyncSecretBundle): JSONObject
    fun decrypt(record: JSONObject): SyncSecretBundle
}

class AndroidKeystoreSyncSecretCipher(
    private val crypto: AndroidVaultCrypto = AndroidVaultCrypto(),
) : SyncSecretCipher {
    override fun encrypt(secrets: SyncSecretBundle): JSONObject {
        crypto.ensureKeystoreWrappingKey()
        val payload = JSONObject()
            .put("webdavPassword", secrets.webdavPassword)
            .put("presignedDownloadUrl", secrets.presignedDownloadUrl)
            .put("presignedUploadUrl", secrets.presignedUploadUrl)
            .put("objectStorageAccessKeyId", secrets.objectStorageAccessKeyId)
            .put("objectStorageSecretAccessKey", secrets.objectStorageSecretAccessKey)
            .put("updatedAt", Instant.now().toString())
            .toString()
        val encrypted = crypto.encryptWithKeystoreWrappingKey(payload.toByteArray(StandardCharsets.UTF_8))
        return JSONObject()
            .put("ciphertext", encrypted.ciphertext)
            .put("nonce", encrypted.nonce)
            .put("mac", encrypted.mac)
            .put("version", encrypted.version)
    }

    override fun decrypt(record: JSONObject): SyncSecretBundle {
        crypto.ensureKeystoreWrappingKey()
        val decrypted = crypto.decryptWithKeystoreWrappingKey(
            ciphertextBase64 = record.optString("ciphertext"),
            nonceBase64 = record.optString("nonce"),
            macBase64 = record.optString("mac"),
        )
        val json = JSONObject(String(decrypted, StandardCharsets.UTF_8))
        return SyncSecretBundle(
            webdavPassword = json.optString("webdavPassword"),
            presignedDownloadUrl = json.optString("presignedDownloadUrl"),
            presignedUploadUrl = json.optString("presignedUploadUrl"),
            objectStorageAccessKeyId = json.optString("objectStorageAccessKeyId"),
            objectStorageSecretAccessKey = json.optString("objectStorageSecretAccessKey"),
        )
    }
}

class InMemorySyncSecretStore : SyncSecretStore {
    private val storage = mutableMapOf<String, SyncSecretBundle>()

    override fun load(deviceId: String): SyncSecretBundle =
        storage[deviceId] ?: SyncSecretBundle.EMPTY

    override fun save(secrets: SyncSecretBundle, deviceId: String) {
        if (secrets.isEmpty) {
            storage.remove(deviceId)
        } else {
            storage[deviceId] = secrets
        }
    }

    override fun delete(deviceId: String) {
        storage.remove(deviceId)
    }
}
