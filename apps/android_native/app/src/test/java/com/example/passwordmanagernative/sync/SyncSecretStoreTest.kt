package com.example.passwordmanagernative.sync

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
        )

        val secrets = settings.syncSecrets
        val redacted = settings.redactedForPlaintextStorage()
        val restored = redacted.applyingSecrets(secrets)

        assertEquals("webdav-password", secrets.webdavPassword)
        assertEquals("https://download.example.com/vault", secrets.presignedDownloadUrl)
        assertEquals("https://upload.example.com/vault", secrets.presignedUploadUrl)
        assertTrue(redacted.webdavPassword.isEmpty())
        assertTrue(redacted.presignedDownloadUrl.isEmpty())
        assertTrue(redacted.presignedUploadUrl.isEmpty())
        assertEquals(settings.webdavPassword, restored.webdavPassword)
        assertEquals(settings.presignedDownloadUrl, restored.presignedDownloadUrl)
        assertEquals(settings.presignedUploadUrl, restored.presignedUploadUrl)
    }

    @Test
    fun inMemorySecretStoreReplacesAndDeletesSecrets() {
        val store = InMemorySyncSecretStore()
        val deviceId = "device-1"
        val secrets = SyncSecretBundle(
            webdavPassword = "webdav-password",
            presignedDownloadUrl = "https://download.example.com/vault",
            presignedUploadUrl = "https://upload.example.com/vault",
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
        )

        store.save(secrets, "device-1")
        val raw = file.readText()
        val loaded = store.load("device-1")

        assertEquals(secrets, loaded)
        assertFalse(raw.contains("webdav-password"))
        assertFalse(raw.contains("https://download.example.com/vault"))
        assertFalse(raw.contains("https://upload.example.com/vault"))
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
        )
    }
}
