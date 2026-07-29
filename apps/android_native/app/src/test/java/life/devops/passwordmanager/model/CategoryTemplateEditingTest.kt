package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CategoryTemplateEditingTest {
    @Test
    fun onlyTextAndFieldReferenceFieldsAreEditable() {
        assertTrue(isEditableCategoryFieldType("text"))
        assertTrue(isEditableCategoryFieldType("fieldReference"))
        assertTrue(isEditableCategoryFieldType(""))
        assertFalse(isEditableCategoryFieldType("entryReference"))
        assertFalse(isEditableCategoryFieldType("futureRelationV3"))
    }

    @Test
    fun saveKeepsBaseFieldsAndAppliesEditableFieldChanges() {
        val notes = FieldTemplate(id = "legacy-notes", name = "Notes")
        val owner = FieldTemplate(
            id = "legacy-owner",
            name = "Owner",
            valueType = "fieldReference",
            targetCategory = "Accounts",
            targetFieldId = "account-email",
        )
        val removable = FieldTemplate(id = "legacy-removable", name = "Region")

        val saved = categoryTemplateFieldsForUserSave(
            existing = CategoryTemplate.defaultCategoryFields() + notes + owner + removable,
            requestedCustomFields = listOf(
                notes.copy(name = "Updated notes"),
                owner.copy(
                    name = "Primary owner",
                    targetCategory = " Identity ",
                    targetFieldId = " identity-email ",
                ),
            ),
        )

        assertEquals(listOf("名称", "备注"), saved.take(2).map { it.name })
        assertEquals("legacy-notes", saved.single { it.name == "Updated notes" }.id)
        assertEquals(
            owner.copy(
                name = "Primary owner",
                targetCategory = "Identity",
                targetFieldId = " identity-email ",
            ),
            saved.single { it.id == owner.id },
        )
        assertTrue(saved.none { it.id == removable.id })
    }

    @Test
    fun storedValuesPreventDeletionAndTextReferenceTypeChanges() {
        val text = FieldTemplate(id = "stored-text", name = "Notes")
        val reference = FieldTemplate(
            id = "stored-reference",
            name = "Owner",
            valueType = "fieldReference",
            targetCategory = "Accounts",
            targetFieldId = "account-email",
        )
        val storedIds = setOf(text.id, reference.id)

        val deletionAttempt = categoryTemplateFieldsForUserSave(
            existing = listOf(text, reference),
            requestedCustomFields = emptyList(),
            storedValueFieldIds = storedIds,
        )
        assertTrue(deletionAttempt.containsAll(listOf(text, reference)))

        val typeChangeAttempt = categoryTemplateFieldsForUserSave(
            existing = listOf(text, reference),
            requestedCustomFields = listOf(
                text.copy(
                    valueType = "fieldReference",
                    targetCategory = "Accounts",
                    targetFieldId = "account-email",
                ),
                reference.copy(valueType = "text", targetCategory = ""),
            ),
            storedValueFieldIds = storedIds,
        )
        assertEquals(text, typeChangeAttempt.single { it.id == text.id })
        assertEquals(reference, typeChangeAttempt.single { it.id == reference.id })
    }

    @Test
    fun storedReferenceAllowsRenameAndTargetChanges() {
        val reference = FieldTemplate(
            id = "stored-reference",
            name = "Owner",
            valueType = "fieldReference",
            targetCategory = "Accounts",
            targetFieldId = "account-email",
        )

        val saved = categoryTemplateFieldsForUserSave(
            existing = listOf(reference),
            requestedCustomFields = listOf(
                reference.copy(
                    name = "Primary owner",
                    targetCategory = " Identity ",
                    targetFieldId = " identity-email ",
                ),
            ),
            storedValueFieldIds = setOf(reference.id),
        )

        assertEquals(
            reference.copy(
                name = "Primary owner",
                targetCategory = "Identity",
                targetFieldId = " identity-email ",
            ),
            saved.single { it.id == reference.id },
        )
    }

    @Test
    fun unknownFieldTypesRemainReadOnlyAndPreserveMetadataVerbatim() {
        val unknown = FieldTemplate(
            id = "future-field",
            name = "Future",
            valueType = "futureRelationV3",
            targetCategory = "  Future Targets  ",
        )

        val omitted = categoryTemplateFieldsForUserSave(
            existing = listOf(unknown),
            requestedCustomFields = emptyList(),
        )
        val rewriteAttempt = categoryTemplateFieldsForUserSave(
            existing = listOf(unknown),
            requestedCustomFields = listOf(unknown.copy(name = "Changed", valueType = "text")),
        )

        assertEquals(unknown, omitted.single { it.id == unknown.id })
        assertEquals(unknown, rewriteAttempt.single { it.id == unknown.id })
    }

    @Test
    fun legacyEntryReferenceRemainsReadOnlyAndPreservesMetadataVerbatim() {
        val legacy = FieldTemplate(
            id = "legacy-entry-reference",
            name = "Owner",
            valueType = "entryReference",
            targetCategory = "  Accounts  ",
        )

        val omitted = categoryTemplateFieldsForUserSave(
            existing = listOf(legacy),
            requestedCustomFields = emptyList(),
        )
        val rewriteAttempt = categoryTemplateFieldsForUserSave(
            existing = listOf(legacy),
            requestedCustomFields = listOf(legacy.copy(name = "Changed", valueType = "fieldReference")),
        )

        assertEquals(legacy, omitted.single { it.id == legacy.id })
        assertEquals(legacy, rewriteAttempt.single { it.id == legacy.id })
    }

    @Test
    fun newFieldsUseCanonicalLowercaseUuidAndLegacyIdsStayUnchanged() {
        val created = newCategoryTemplateField(
            name = " Owner ",
            valueType = "fieldReference",
            targetCategory = " Accounts ",
            targetFieldId = " account-email ",
        )
        val canonicalLowercaseUuid =
            Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        assertTrue(canonicalLowercaseUuid.matches(created.id))
        assertEquals("Owner", created.name)
        assertEquals("Accounts", created.targetCategory)
        assertEquals(" account-email ", created.targetFieldId)

        val legacy = FieldTemplate(id = "template_owner", name = "Owner")
        val saved = categoryTemplateFieldsForUserSave(
            existing = listOf(legacy),
            requestedCustomFields = listOf(legacy.copy(name = "Primary owner")),
        )
        assertEquals("template_owner", saved.single { it.name == "Primary owner" }.id)
    }

    @Test
    fun nonEmptyWhitespaceIdsRemainOpaqueAndMatchExactly() {
        val legacy = FieldTemplate(id = "   ", name = "Owner")

        val saved = categoryTemplateFieldsForUserSave(
            existing = listOf(legacy),
            requestedCustomFields = listOf(legacy.copy(name = "Primary owner")),
        )

        assertEquals("   ", saved.single { it.name == "Primary owner" }.id)
    }
}
