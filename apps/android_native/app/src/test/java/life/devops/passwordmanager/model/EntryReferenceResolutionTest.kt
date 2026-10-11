package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class EntryReferenceResolutionTest {
    @Test
    fun resolvesExactTargetIdToSafeDisplayProjection() {
        val target = targetEntry(
            id = "account-id",
            label = "Production Account",
            category = "Accounts",
            password = "must-not-be-projected",
        )

        val resolution = resolveEntryReference(
            field = referenceField(value = target.id),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(target),
        )

        assertEquals(
            EntryReferenceResolution(
                status = EntryReferenceStatus.RESOLVED,
                target = EntryReferenceTarget(
                    id = "account-id",
                    label = "Production Account",
                    category = "Accounts",
                ),
            ),
            resolution,
        )
    }

    @Test
    fun emptyValueWinsBeforeTargetLookup() {
        val resolution = resolveEntryReference(
            field = referenceField(value = "   "),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(targetEntry(id = "   ", category = "Other")),
        )

        assertEquals(
            EntryReferenceResolution(status = EntryReferenceStatus.EMPTY),
            resolution,
        )
    }

    @Test
    fun missingTargetUsesCaseSensitiveExactIdMatching() {
        val resolution = resolveEntryReference(
            field = referenceField(value = "Target-ID"),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(targetEntry(id = "target-id", category = "Accounts")),
        )

        assertEquals(
            EntryReferenceResolution(status = EntryReferenceStatus.MISSING),
            resolution,
        )
    }

    @Test
    fun deletedWinsBeforeCategoryMismatch() {
        val target = targetEntry(
            id = "deleted-account",
            category = "Archive",
            isDeleted = true,
        )

        val resolution = resolveEntryReference(
            field = referenceField(value = target.id),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(target),
        )

        assertEquals(EntryReferenceStatus.DELETED, resolution?.status)
        assertEquals(target.id, resolution?.target?.id)
        assertEquals("Archive", resolution?.target?.category)
    }

    @Test
    fun activeTargetOutsideConfiguredCategoryIsMismatch() {
        val target = targetEntry(id = "server-id", category = "Servers")

        val resolution = resolveEntryReference(
            field = referenceField(value = target.id),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(target),
        )

        assertEquals(EntryReferenceStatus.CATEGORY_MISMATCH, resolution?.status)
        assertEquals(target.id, resolution?.target?.id)
    }

    @Test
    fun targetCategoryMatchingIsTrimmedAndCaseInsensitive() {
        val target = targetEntry(id = "account-id", category = " Accounts ")

        val resolution = resolveEntryReference(
            field = referenceField(value = target.id),
            template = referenceTemplate(targetCategory = " accounts "),
            entries = listOf(target),
        )

        assertEquals(EntryReferenceStatus.RESOLVED, resolution?.status)
        assertEquals("Accounts", resolution?.target?.category)
    }

    @Test
    fun emptyTargetCategoryDoesNotRestrictResolvedTarget() {
        val target = targetEntry(id = "server-id", category = "Servers")

        val resolution = resolveEntryReference(
            field = referenceField(value = target.id),
            template = referenceTemplate(targetCategory = "   "),
            entries = listOf(target),
        )

        assertEquals(EntryReferenceStatus.RESOLVED, resolution?.status)
        assertEquals("Servers", resolution?.target?.category)
    }

    @Test
    fun nonReferenceAndUnknownTemplateFieldsAreNotResolved() {
        val target = targetEntry(id = "account-id", category = "Accounts")
        val textTemplate = CategoryTemplate(
            category = "Servers",
            fields = listOf(FieldTemplate(id = "template-owner", name = "Owner")),
        )

        assertNull(
            resolveEntryReference(
                field = referenceField(value = target.id),
                template = textTemplate,
                entries = listOf(target),
            )
        )
        assertNull(
            resolveEntryReference(
                field = referenceField(value = target.id).copy(
                    templateFieldId = "missing-template-id",
                    name = "Owner",
                ),
                template = referenceTemplate(targetCategory = "Accounts"),
                entries = listOf(target),
            )
        )
    }

    @Test
    fun missingTemplateFieldIdFallsBackToLegacyFieldName() {
        val target = targetEntry(id = "account-id", category = "Accounts")

        val resolution = resolveEntryReference(
            field = referenceField(value = target.id).copy(
                templateFieldId = "",
                name = " owner ",
            ),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(target),
        )

        assertEquals(EntryReferenceStatus.RESOLVED, resolution?.status)
    }

    @Test
    fun whitespaceTemplateFieldIdDoesNotFallBackToFieldName() {
        val target = targetEntry(id = "account-id", category = "Accounts")

        val resolution = resolveEntryReference(
            field = referenceField(value = target.id).copy(
                templateFieldId = "   ",
                name = "Owner",
            ),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(target),
        )

        assertNull(resolution)
    }

    @Test
    fun sameLabelTargetsResolveByIdRatherThanLabel() {
        val first = targetEntry(id = "account-a", label = "Shared", category = "Accounts")
        val second = targetEntry(id = "account-b", label = "Shared", category = "Accounts")

        val resolution = resolveEntryReference(
            field = referenceField(value = second.id),
            template = referenceTemplate(targetCategory = "Accounts"),
            entries = listOf(first, second),
        )

        assertEquals(EntryReferenceStatus.RESOLVED, resolution?.status)
        assertEquals("account-b", resolution?.target?.id)
    }

    private fun referenceTemplate(targetCategory: String): CategoryTemplate =
        CategoryTemplate(
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

    private fun referenceField(value: String): CustomField =
        CustomField(
            id = "owner-field",
            templateFieldId = "template-owner",
            name = "Owner",
            value = value,
        )

    private fun targetEntry(
        id: String,
        label: String = "Target",
        category: String,
        password: String = "secret",
        isDeleted: Boolean = false,
    ): VaultEntry =
        VaultEntry(
            id = id,
            label = label,
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(
                CredentialPayload(
                    username = "private-user",
                    password = password,
                    token = "private-token",
                    secretKey = "private-secret-key",
                    category = category,
                )
            ),
            isDeleted = isDeleted,
        )
}
