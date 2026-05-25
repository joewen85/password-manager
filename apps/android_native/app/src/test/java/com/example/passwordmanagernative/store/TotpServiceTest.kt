package com.example.passwordmanagernative.store

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TotpServiceTest {
    private val service = TotpService(skewWindows = 1)
    private val fixtureTime = Instant.ofEpochSecond(59)

    @Test
    fun generatesRfc6238Sha1FixtureCode() {
        val code = service.generateCode(
            secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            time = fixtureTime,
        )

        assertEquals("287082", code)
    }

    @Test
    fun verifiesCurrentAndSkewWindowCodes() {
        val previousWindowCode = service.generateCode(
            secret = "JBSWY3DPEHPK3PXP",
            time = fixtureTime.minusSeconds(30),
        )

        assertTrue(service.verifyCode("JBSWY3DPEHPK3PXP", previousWindowCode, fixtureTime))
    }

    @Test
    fun rejectsMalformedOrIncorrectCodes() {
        assertFalse(service.verifyCode("JBSWY3DPEHPK3PXP", "12345", fixtureTime))
        assertFalse(service.verifyCode("JBSWY3DPEHPK3PXP", "000000", fixtureTime))
        assertFalse(service.verifyCode("not-base32", "000000", fixtureTime))
    }
}
