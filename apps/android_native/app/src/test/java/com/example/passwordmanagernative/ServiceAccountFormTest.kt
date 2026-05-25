package com.example.passwordmanagernative

import com.example.passwordmanagernative.model.ServiceAccount
import kotlin.test.Test
import kotlin.test.assertEquals

class ServiceAccountFormTest {
    @Test
    fun serviceAccountsRoundTripThroughCompactTextFieldFormat() {
        val accounts = listOf(
            ServiceAccount("svc-admin", "svc-password", "primary account"),
            ServiceAccount("svc-readonly", "readonly-password", ""),
        )

        val encoded = formatServiceAccounts(accounts)
        val decoded = parseServiceAccounts(encoded)

        assertEquals("svc-admin:svc-password:primary account; svc-readonly:readonly-password:", encoded)
        assertEquals(accounts, decoded)
    }

    @Test
    fun serviceAccountParserSkipsBlankEntriesAndPreservesNotesWithColons() {
        val decoded = parseServiceAccounts(" ; svc:secret:note:with:colon; missing-password")

        assertEquals(
            listOf(
                ServiceAccount("svc", "secret", "note:with:colon"),
                ServiceAccount("missing-password", "", ""),
            ),
            decoded,
        )
    }
}
