package life.devops.passwordmanager.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class AndroidKeystoreSyncSecretStoreInstrumentedTest {
    @Test
    fun keystoreWrappedFileStoreRoundTripsWithoutPlaintextSecrets() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.filesDir, "instrumented-sync-secrets.json")
        file.delete()
        val store = FileSyncSecretStore(file, AndroidKeystoreSyncSecretCipher())
        val secrets = SyncSecretBundle(
            webdavPassword = "device-webdav-password",
            presignedDownloadUrl = "https://download.example.com/vault?signature=device-read",
            presignedUploadUrl = "https://upload.example.com/vault?signature=device-write",
        )

        store.save(secrets, "instrumented-device")
        val raw = file.readText()
        val loaded = store.load("instrumented-device")

        assertEquals(secrets, loaded)
        assertTrue(raw.contains("ciphertext"))
        assertTrue(raw.contains("nonce"))
        assertTrue(raw.contains("mac"))
        assertFalse(raw.contains("device-webdav-password"))
        assertFalse(raw.contains("signature=device-read"))
        assertFalse(raw.contains("signature=device-write"))

        store.delete("instrumented-device")
        assertEquals(SyncSecretBundle.EMPTY, store.load("instrumented-device"))
        file.delete()
    }
}
