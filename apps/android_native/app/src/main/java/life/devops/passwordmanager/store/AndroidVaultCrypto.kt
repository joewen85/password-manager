package life.devops.passwordmanager.store

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import life.devops.passwordmanager.model.EncryptedPayloadRecord
import life.devops.passwordmanager.model.MasterKeyRecord
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class AndroidVaultCrypto {
    fun makeMasterKeyRecord(password: String): MasterKeyRecord {
        val salt = randomBytes(16)
        val metadataSalt = randomBytes(16)
        val verifier = deriveKey(password, salt, DEFAULT_ITERATIONS)
        return MasterKeyRecord(
            saltBase64 = salt.base64(),
            iterations = DEFAULT_ITERATIONS,
            verifierBase64 = verifier.base64(),
            metadataSaltBase64 = metadataSalt.base64(),
            metadataIterations = DEFAULT_ITERATIONS,
        )
    }

    fun verify(password: String, record: MasterKeyRecord): ByteArray {
        val derived = deriveKey(password, record.saltBase64, record.iterations)
        val verifier = record.verifierBase64.fromBase64()
        if (!constantTimeEquals(derived, verifier)) {
            throw SecurityException("Vault authentication failed.")
        }
        return derived
    }

    fun deriveKey(password: String, saltBase64: String, iterations: Int): ByteArray =
        deriveKey(password, saltBase64.fromBase64(), iterations)

    fun encrypt(plaintext: ByteArray, keyBytes: ByteArray): EncryptedPayloadRecord {
        val nonce = randomBytes(12)
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(keyBytes, "AES"),
            GCMParameterSpec(GCM_TAG_BITS, nonce),
        )
        val sealed = cipher.doFinal(plaintext)
        val ciphertext = sealed.copyOfRange(0, sealed.size - GCM_TAG_BYTES)
        val tag = sealed.copyOfRange(sealed.size - GCM_TAG_BYTES, sealed.size)
        return EncryptedPayloadRecord(
            ciphertext = ciphertext.base64(),
            nonce = nonce.base64(),
            mac = tag.base64(),
            version = 1,
        )
    }

    fun decrypt(payload: EncryptedPayloadRecord, keyBytes: ByteArray): ByteArray {
        val ciphertext = payload.ciphertext.fromBase64()
        val tag = payload.mac.fromBase64()
        val sealed = ciphertext + tag
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(keyBytes, "AES"),
            GCMParameterSpec(GCM_TAG_BITS, payload.nonce.fromBase64()),
        )
        return cipher.doFinal(sealed)
    }

    fun ensureKeystoreWrappingKey() {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (keyStore.containsAlias(KEY_ALIAS)) return
        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        keyGenerator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        keyGenerator.generateKey()
    }

    fun encryptWithKeystoreWrappingKey(plaintext: ByteArray): EncryptedPayloadRecord {
        val key = loadKeystoreWrappingKey()
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val sealed = cipher.doFinal(plaintext)
        val ciphertext = sealed.copyOfRange(0, sealed.size - GCM_TAG_BYTES)
        val tag = sealed.copyOfRange(sealed.size - GCM_TAG_BYTES, sealed.size)
        return EncryptedPayloadRecord(
            ciphertext = ciphertext.base64(),
            nonce = cipher.iv.base64(),
            mac = tag.base64(),
            version = 1,
        )
    }

    fun decryptWithKeystoreWrappingKey(
        ciphertextBase64: String,
        nonceBase64: String,
        macBase64: String,
    ): ByteArray {
        val key = loadKeystoreWrappingKey()
        val sealed = ciphertextBase64.fromBase64() + macBase64.fromBase64()
        val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonceBase64.fromBase64()))
        return cipher.doFinal(sealed)
    }

    private fun loadKeystoreWrappingKey(): SecretKey {
        ensureKeystoreWrappingKey()
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return keyStore.getKey(KEY_ALIAS, null) as SecretKey
    }

    private fun deriveKey(password: String, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, 256)
        return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(spec)
            .encoded
    }

    private fun randomBytes(count: Int): ByteArray =
        ByteArray(count).also { secureRandom.nextBytes(it) }

    private fun constantTimeEquals(left: ByteArray, right: ByteArray): Boolean =
        left.size == right.size && run {
            var diff = 0
            for (index in left.indices) {
                diff = diff or (left[index].toInt() xor right[index].toInt())
            }
            diff == 0
        }

    private fun ByteArray.base64(): String =
        Base64.getEncoder().encodeToString(this)

    private fun String.fromBase64(): ByteArray =
        Base64.getDecoder().decode(this)

    companion object {
        const val DEFAULT_ITERATIONS = 600_000
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "password_manager_native_vault_wrapping_key"
        private const val AES_GCM_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = 16
        private val secureRandom = SecureRandom()
    }
}
