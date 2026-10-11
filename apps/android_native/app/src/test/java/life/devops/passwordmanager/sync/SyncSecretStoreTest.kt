package life.devops.passwordmanager.sync

import org.json.JSONObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SyncSecretStoreTest {
    @Test
    fun settingsCanBeRedactedAndRestoredWithSecrets() {
        val settings = SyncSettings.defaults(deviceId = "device-1").copy(
            webdavPassword = "webdav-password",
            presignedDownloadUrl = "https://download.example.com/vault",
            presignedUploadUrl = "https://upload.example.com/vault",
            objectStorageAccessKeyId = "object-ak",
            objectStorageSecretAccessKey = "object-sk",
        )

        val secrets = settings.syncSecrets
        val redacted = settings.redactedForPlaintextStorage()
        val restored = redacted.applyingSecrets(secrets)

        assertEquals("webdav-password", secrets.webdavPassword)
        assertEquals("https://download.example.com/vault", secrets.presignedDownloadUrl)
        assertEquals("https://upload.example.com/vault", secrets.presignedUploadUrl)
        assertEquals("object-ak", secrets.objectStorageAccessKeyId)
        assertEquals("object-sk", secrets.objectStorageSecretAccessKey)
        assertTrue(redacted.webdavPassword.isEmpty())
        assertTrue(redacted.presignedDownloadUrl.isEmpty())
        assertTrue(redacted.presignedUploadUrl.isEmpty())
        assertTrue(redacted.objectStorageAccessKeyId.isEmpty())
        assertTrue(redacted.objectStorageSecretAccessKey.isEmpty())
        assertEquals(settings.webdavPassword, restored.webdavPassword)
        assertEquals(settings.presignedDownloadUrl, restored.presignedDownloadUrl)
        assertEquals(settings.presignedUploadUrl, restored.presignedUploadUrl)
        assertEquals(settings.objectStorageAccessKeyId, restored.objectStorageAccessKeyId)
        assertEquals(settings.objectStorageSecretAccessKey, restored.objectStorageSecretAccessKey)
    }

    @Test
    fun inMemorySecretStoreReplacesAndDeletesSecrets() {
        val store = InMemorySyncSecretStore()
        val deviceId = "device-1"
        val secrets = SyncSecretBundle(
            webdavPassword = "webdav-password",
            presignedDownloadUrl = "https://download.example.com/vault",
            presignedUploadUrl = "https://upload.example.com/vault",
            objectStorageAccessKeyId = "object-ak",
            objectStorageSecretAccessKey = "object-sk",
        )

        assertEquals(SyncSecretBundle.EMPTY, store.load(deviceId))
        store.save(secrets, deviceId)
        assertEquals(secrets, store.load(deviceId))
        store.save(SyncSecretBundle.EMPTY, deviceId)
        assertEquals(SyncSecretBundle.EMPTY, store.load(deviceId))
        store.save(secrets, deviceId)
        store.delete(deviceId)
        assertEquals(SyncSecretBundle.EMPTY, store.load(deviceId))
    }

    @Test
    fun fileStoreUsesCipherAndDoesNotPersistPlaintext() {
        val file = File.createTempFile("sync-secrets", ".json")
        file.deleteOnExit()
        val store = FileSyncSecretStore(file, ReversingTestCipher())
        val secrets = SyncSecretBundle(
            webdavPassword = "webdav-password",
            presignedDownloadUrl = "https://download.example.com/vault",
            presignedUploadUrl = "https://upload.example.com/vault",
            objectStorageAccessKeyId = "object-ak",
            objectStorageSecretAccessKey = "object-sk",
        )

        store.save(secrets, "device-1")
        val raw = file.readText()
        val loaded = store.load("device-1")

        assertEquals(secrets, loaded)
        assertFalse(raw.contains("webdav-password"))
        assertFalse(raw.contains("https://download.example.com/vault"))
        assertFalse(raw.contains("https://upload.example.com/vault"))
        assertFalse(raw.contains("object-ak"))
        assertFalse(raw.contains("object-sk"))
        store.delete("device-1")
        assertEquals(SyncSecretBundle.EMPTY, store.load("device-1"))
    }
}

private class ReversingTestCipher : SyncSecretCipher {
    override fun encrypt(secrets: SyncSecretBundle): JSONObject {
        val joined = listOf(
            secrets.webdavPassword,
            secrets.presignedDownloadUrl,
            secrets.presignedUploadUrl,
            secrets.objectStorageAccessKeyId,
            secrets.objectStorageSecretAccessKey,
        ).joinToString(separator = "\n")
        return JSONObject()
            .put("ciphertext", joined.reversed())
            .put("version", 1)
    }

    override fun decrypt(record: JSONObject): SyncSecretBundle {
        val parts = record.getString("ciphertext").reversed().split("\n")
        return SyncSecretBundle(
            webdavPassword = parts.getOrElse(0) { "" },
            presignedDownloadUrl = parts.getOrElse(1) { "" },
            presignedUploadUrl = parts.getOrElse(2) { "" },
            objectStorageAccessKeyId = parts.getOrElse(3) { "" },
            objectStorageSecretAccessKey = parts.getOrElse(4) { "" },
        )
    }
}
