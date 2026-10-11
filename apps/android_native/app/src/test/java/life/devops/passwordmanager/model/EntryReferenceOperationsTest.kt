package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EntryReferenceOperationsTest {
    @Test
    fun safeSearchProjectionUsesOnlyAllowedValuesForEveryFieldSemantic() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-notes", name = "Notes"),
                FieldTemplate(
                    id = "template-owner",
                    name = "Owner",
                    valueType = "entryReference",
                    targetCategory = "Accounts",
                ),
                FieldTemplate(id = "template-future", name = "Future", valueType = "futureType"),
            ),
        )
        val target = entry(
            id = "RAW-TARGET-ID",
            label = "Primary Account",
            category = " Accounts ",
            secret = "target-secret",
        )
        val source = entry(
            id = "source",
            label = "Server",
            category = "Servers",
            customFields = listOf(
                CustomField(id = "text", templateFieldId = "template-notes", name = "Notes", value = "public-note"),
                CustomField(id = "reference", templateFieldId = "template-owner", name = "Owner", value = target.id),
                CustomField(id = "unknown", templateFieldId = "template-future", name = "Future", value = "unknown-secret"),
                CustomField(id = "orphan", templateFieldId = "missing-template", name = "Notes", value = "orphan-secret"),
                CustomField(id = "legacy", name = "Region", value = "legacy-visible"),
            ),
        )

        val projected = source.withEntryReferenceSearchProjection(
            template = template,
            entriesById = mapOf(target.id to target),
        )
        val valuesById = projected.customFields.associate { field -> field.id to field.value }
        val allValues = projected.customFields.joinToString(" ") { field -> field.value }

        assertEquals("public-note", valuesById["text"])
        assertEquals("Primary Account Accounts", valuesById["reference"])
        assertEquals("", valuesById["unknown"])
        assertEquals("", valuesById["orphan"])
        assertEquals("legacy-visible", valuesById["legacy"])
        listOf(target.id, "target-secret", "unknown-secret", "orphan-secret").forEach { forbidden ->
            assertFalse(allValues.contains(forbidden))
        }
    }

    @Test
    fun unresolvedReferencesContributeNoRawSearchValue() {
        val template = referenceTemplate(targetCategory = "Accounts")
        val deleted = entry(id = "deleted", label = "Deleted", category = "Accounts", isDeleted = true)
        val mismatch = entry(id = "mismatch", label = "Archive", category = "Archive")
        val source = entry(
            id = "source",
            label = "Server",
            category = "Servers",
            customFields = listOf(
                referenceField("empty", ""),
                referenceField("missing", "missing-id"),
                referenceField("deleted-field", deleted.id),
                referenceField("mismatch-field", mismatch.id),
            ),
        )

        val projected = source.withEntryReferenceSearchProjection(
            template = template,
            entriesById = mapOf(deleted.id to deleted, mismatch.id to mismatch),
        )

        assertTrue(projected.customFields.all { field -> field.value.isEmpty() })
    }

    @Test
    fun candidatesAreLiveCategoryScopedAndSearchOnlySafeProjectionFields() {
        val alpha = entry(
            id = "account-a",
            label = "Alpha Account",
            category = " Accounts ",
            secret = "alpha-private-secret",
            customFields = listOf(CustomField(name = "Hidden", value = "hidden-custom-secret")),
        )
        val beta = entry(id = "account-b", label = "Beta Account", category = "accounts")
        val other = entry(id = "server", label = "Gateway", category = "Servers")
        val deleted = entry(id = "deleted", label = "Deleted Account", category = "Accounts", isDeleted = true)
        val entries = listOf(other, beta, deleted, alpha)

        assertEquals(
            listOf("account-a", "account-b"),
            entryReferenceCandidates(entries, " accounts ", "").map { candidate -> candidate.id },
        )
        assertEquals(
            listOf("account-b"),
            entryReferenceCandidates(entries, "ACCOUNTS", "beta").map { candidate -> candidate.id },
        )
        assertEquals(
            listOf("account-a", "account-b"),
            entryReferenceCandidates(entries, "", "accounts").map { candidate -> candidate.id },
        )
        assertTrue(entryReferenceCandidates(entries, "", "alpha-private-secret").isEmpty())
        assertTrue(entryReferenceCandidates(entries, "", "hidden-custom-secret").isEmpty())
        assertEquals(
            EntryReferenceCandidate(
                id = "account-a",
                label = "Alpha Account",
                category = "Accounts",
            ),
            entryReferenceCandidates(entries, "Accounts", "Alpha").single(),
        )
    }

    private fun referenceTemplate(targetCategory: String): CategoryTemplate = CategoryTemplate(
        category = "Servers",
        fields = listOf(
            FieldTemplate(
                id = "template-owner",
                name = "Owner",
                valueType = "entryReference",
                targetCategory = targetCategory,
            )
        ),
    )

    private fun referenceField(id: String, value: String): CustomField = CustomField(
        id = id,
        templateFieldId = "template-owner",
        name = "Owner",
        value = value,
    )

    private fun entry(
        id: String,
        label: String,
        category: String,
        secret: String = "secret",
        customFields: List<CustomField> = emptyList(),
        isDeleted: Boolean = false,
    ): VaultEntry = VaultEntry(
        id = id,
        label = label,
        type = VaultEntryType.CREDENTIAL,
        payload = VaultPayload.Credential(
            CredentialPayload(
                username = "private-user",
                password = secret,
                token = "private-token",
                secretKey = "private-secret-key",
                category = category,
            )
        ),
        customFields = customFields,
        isDeleted = isDeleted,
    )
}
