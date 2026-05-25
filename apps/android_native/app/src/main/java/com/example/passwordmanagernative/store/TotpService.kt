package com.example.passwordmanagernative.store

import java.nio.ByteBuffer
import java.time.Instant
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.pow

class TotpService(
    private val periodSeconds: Long = 30,
    private val digits: Int = 6,
    private val skewWindows: Int = 1,
) {
    fun generateCode(secret: String, time: Instant = Instant.now()): String {
        val key = decodeBase32(secret)
        val counter = time.epochSecond / periodSeconds
        return code(counter, key)
    }

    fun verifyCode(secret: String, code: String, time: Instant = Instant.now()): Boolean {
        val normalizedCode = code.trim()
        if (normalizedCode.length != digits || normalizedCode.any { !it.isDigit() }) return false
        val key = runCatching { decodeBase32(secret) }.getOrNull() ?: return false
        val counter = time.epochSecond / periodSeconds
        for (offset in -skewWindows..skewWindows) {
            val expected = code(counter + offset, key)
            if (constantTimeEquals(expected, normalizedCode)) return true
        }
        return false
    }

    private fun code(counter: Long, key: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA1")
        mac.init(SecretKeySpec(key, "HmacSHA1"))
        val hash = mac.doFinal(ByteBuffer.allocate(Long.SIZE_BYTES).putLong(counter).array())
        val offset = (hash.last().toInt() and 0x0f)
        val binary = ((hash[offset].toInt() and 0x7f) shl 24) or
            ((hash[offset + 1].toInt() and 0xff) shl 16) or
            ((hash[offset + 2].toInt() and 0xff) shl 8) or
            (hash[offset + 3].toInt() and 0xff)
        val modulus = 10.0.pow(digits).toInt()
        return (binary % modulus).toString().padStart(digits, '0')
    }

    private fun decodeBase32(secret: String): ByteArray {
        val normalized = secret.uppercase(Locale.US).filter { !it.isWhitespace() && it != '=' }
        require(normalized.isNotEmpty()) { "TOTP secret is empty." }
        var buffer = 0
        var bitsLeft = 0
        val bytes = mutableListOf<Byte>()
        normalized.forEach { character ->
            val value = alphabet.indexOf(character)
            require(value >= 0) { "TOTP secret is not valid Base32." }
            buffer = (buffer shl 5) or value
            bitsLeft += 5
            if (bitsLeft >= 8) {
                bytes += ((buffer shr (bitsLeft - 8)) and 0xff).toByte()
                bitsLeft -= 8
            }
        }
        return bytes.toByteArray()
    }

    private fun constantTimeEquals(left: String, right: String): Boolean {
        val leftBytes = left.toByteArray()
        val rightBytes = right.toByteArray()
        var diff = leftBytes.size xor rightBytes.size
        val maxLength = maxOf(leftBytes.size, rightBytes.size)
        for (index in 0 until maxLength) {
            val leftByte = if (index < leftBytes.size) leftBytes[index].toInt() else 0
            val rightByte = if (index < rightBytes.size) rightBytes[index].toInt() else 0
            diff = diff or (leftByte xor rightByte)
        }
        return diff == 0
    }

    private companion object {
        const val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    }
}
