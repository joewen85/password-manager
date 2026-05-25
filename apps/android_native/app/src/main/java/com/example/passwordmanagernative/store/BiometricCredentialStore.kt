package com.example.passwordmanagernative.store

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class BiometricCredentialStore(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun canAuthenticate(): Boolean =
        BiometricManager.from(appContext).canAuthenticate(BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS

    fun hasSavedCredential(): Boolean =
        prefs.contains(KEY_CIPHERTEXT) && prefs.contains(KEY_NONCE)

    fun clear() {
        prefs.edit()
            .remove(KEY_CIPHERTEXT)
            .remove(KEY_NONCE)
            .apply()
    }

    fun createEncryptCipher(): Cipher {
        val key = getOrCreateKey()
        return Cipher.getInstance(AES_GCM_TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, key)
        }
    }

    fun createDecryptCipher(): Cipher? {
        val nonce = prefs.getString(KEY_NONCE, null)?.fromBase64() ?: return null
        return runCatching {
            val key = loadKey()
            Cipher.getInstance(AES_GCM_TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
            }
        }.getOrElse { error ->
            if (error is KeyPermanentlyInvalidatedException || error.cause is KeyPermanentlyInvalidatedException) {
                clear()
            }
            null
        }
    }

    fun savePassword(cipher: Cipher, password: String) {
        val encrypted = cipher.doFinal(password.toByteArray(Charsets.UTF_8))
        prefs.edit()
            .putString(KEY_CIPHERTEXT, encrypted.base64())
            .putString(KEY_NONCE, cipher.iv.base64())
            .apply()
    }

    fun readPassword(cipher: Cipher): String {
        val encrypted = prefs.getString(KEY_CIPHERTEXT, null)?.fromBase64()
            ?: throw IllegalStateException("Biometric unlock has not been enabled.")
        return cipher.doFinal(encrypted).toString(Charsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (keyStore.containsAlias(KEY_ALIAS)) {
            return keyStore.getKey(KEY_ALIAS, null) as SecretKey
        }
        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }

        keyGenerator.init(builder.build())
        return keyGenerator.generateKey()
    }

    private fun loadKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)
            ?: throw IllegalStateException("Biometric unlock has not been enabled.")
    }

    private fun ByteArray.base64(): String =
        Base64.getEncoder().encodeToString(this)

    private fun String.fromBase64(): ByteArray =
        Base64.getDecoder().decode(this)

    companion object {
        private const val PREFS_NAME = "biometric_unlock"
        private const val KEY_ALIAS = "password_manager_native_biometric_unlock"
        private const val KEY_CIPHERTEXT = "master_password_ciphertext"
        private const val KEY_NONCE = "master_password_nonce"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val AES_GCM_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }
}
