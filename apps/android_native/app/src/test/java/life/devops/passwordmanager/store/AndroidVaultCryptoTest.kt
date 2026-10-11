package life.devops.passwordmanager.store

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class AndroidVaultCryptoTest {
    private val crypto = AndroidVaultCrypto()

    @Test
    fun masterKeyRecordVerifiesCorrectPasswordAndRejectsWrongPassword() {
        val record = crypto.makeMasterKeyRecord("fixture-password")

        val key = crypto.verify("fixture-password", record)

        assertEquals(AndroidVaultCrypto.DEFAULT_ITERATIONS, record.iterations)
        assertEquals(32, key.size)
        assertFailsWith<SecurityException> {
            crypto.verify("wrong-password", record)
        }
    }

    @Test
    fun aesGcmRoundTripsAndDoesNotExposePlaintext() {
        val key = ByteArray(32) { it.toByte() }
        val plaintext = """{"label":"Email","password":"secret"}""".toByteArray()

        val encrypted = crypto.encrypt(plaintext, key)
        val decrypted = crypto.decrypt(encrypted, key)

        assertContentEquals(plaintext, decrypted)
        assertEquals(1, encrypted.version)
        assertFalse(encrypted.ciphertext.contains("Email"))
        assertFalse(encrypted.ciphertext.contains("secret"))
    }
}
