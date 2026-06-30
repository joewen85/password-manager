package life.devops.passwordmanager.sync

import life.devops.passwordmanager.model.EncryptedPayloadRecord
import life.devops.passwordmanager.model.MasterKeyRecord
import life.devops.passwordmanager.store.AndroidVaultCrypto
import life.devops.passwordmanager.store.VaultJson
import org.json.JSONObject
import org.json.JSONObject.NULL
import java.nio.charset.StandardCharsets
import java.time.Instant

class EncryptedRemoteSyncClient(
    private val delegate: RemoteSyncClient,
    private val crypto: AndroidVaultCrypto,
    private val vaultKey: ByteArray,
    private val masterKeyRecord: MasterKeyRecord?,
    private val includeMasterKeyRecord: Boolean,
) : RemoteSyncClient {
    var downloadedPlaintextRemote: Boolean = false
        private set

    override fun metadata(): RemoteSyncMetadata =
        delegate.metadata().let { metadata ->
            metadata.copy(eTag = null, lastModified = null, contentLength = null)
        }

    override fun download(): RemoteSyncResult {
        val download = delegate.download()
        val rawPayload = download.payload?.trim()
        if (!isSuccessfulDownload(download.statusCode) || rawPayload.isNullOrEmpty()) {
            return download
        }
        val encryptedPayload = decodeEncryptedPayload(rawPayload)
        if (encryptedPayload == null) {
            markPlaintextRemoteIfNeeded(rawPayload)
            return download
        }
        return download.copy(payload = encryptedPayload.toJson().toString())
    }

    override fun upload(payload: String): RemoteSyncResult {
        val syncPayload = VaultSyncPayload.fromJson(payload)
        val encryptedVault = crypto.encrypt(
            VaultJson.encodeSnapshot(syncPayload.snapshot).toByteArray(StandardCharsets.UTF_8),
            vaultKey,
        )
        val envelope = JSONObject()
            .put("version", syncPayload.version)
            .put("exportedAt", syncPayload.exportedAt.toString())
            .put("deviceId", syncPayload.deviceId)
            .put("revision", syncPayload.revision)
            .put(
                "masterKeyRecord",
                if (includeMasterKeyRecord) masterKeyRecord?.toJson() ?: NULL else NULL,
            )
            .put("encryptedVault", encryptedVault.toJson())
        return delegate.upload(envelope.toString())
    }

    private fun decodeEncryptedPayload(rawPayload: String): VaultSyncPayload? {
        val json = JSONObject(rawPayload)
        val encryptedVault = json.optJSONObject("encryptedVault")?.toEncryptedPayloadRecord()
            ?: return null
        val decryptedSnapshot = VaultJson.decodeSnapshot(
            String(crypto.decrypt(encryptedVault, vaultKey), StandardCharsets.UTF_8)
        )
        return VaultSyncPayload(
            version = json.optInt("version", 1),
            exportedAt = json.optInstant("exportedAt") ?: Instant.EPOCH,
            deviceId = json.optString("deviceId"),
            revision = json.optInt("revision", 0),
            snapshot = decryptedSnapshot,
        )
    }

    private fun markPlaintextRemoteIfNeeded(rawPayload: String) {
        runCatching { VaultSyncPayload.fromJson(rawPayload) }
            .onSuccess { downloadedPlaintextRemote = true }
    }

    private fun MasterKeyRecord.toJson(): JSONObject =
        JSONObject()
            .put("saltBase64", saltBase64)
            .put("iterations", iterations)
            .put("verifierBase64", verifierBase64)
            .put("metadataSaltBase64", metadataSaltBase64 ?: NULL)
            .put("metadataIterations", metadataIterations ?: NULL)

    private fun EncryptedPayloadRecord.toJson(): JSONObject =
        JSONObject()
            .put("ciphertext", ciphertext)
            .put("nonce", nonce)
            .put("mac", mac)
            .put("version", version)

    private fun JSONObject.toEncryptedPayloadRecord(): EncryptedPayloadRecord =
        EncryptedPayloadRecord(
            ciphertext = optString("ciphertext"),
            nonce = optString("nonce"),
            mac = optString("mac"),
            version = optInt("version", 1),
        )

    private fun JSONObject.optInstant(name: String): Instant? {
        if (!has(name) || isNull(name)) return null
        return runCatching { Instant.parse(optString(name)) }.getOrNull()
    }

    private fun isSuccessfulDownload(statusCode: Int): Boolean =
        statusCode in 200..299 || statusCode == 404
}
