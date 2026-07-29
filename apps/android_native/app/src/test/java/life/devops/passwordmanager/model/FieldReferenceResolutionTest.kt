package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FieldReferenceResolutionTest {
    @Test
    fun resolutionFollowsTheContractPrecedence() {
        val invalidSourceField = sourceField.copy(targetCategory = "", targetFieldId = "")
        assertEquals(
            FieldReferenceStatus.EMPTY,
            resolve(
                field = sourceValue.copy(value = "   "),
                sourceTemplate = sourceTemplate.copy(fields = listOf(invalidSourceField)),
                templates = emptyList(),
                entries = emptyList(),
            )?.status,
        )
        assertEquals(
            FieldReferenceStatus.INVALID_CONFIGURATION,
            resolve(
                sourceTemplate = sourceTemplate.copy(
                    fields = listOf(sourceField.copy(targetCategory = "")),
                ),
            )?.status,
        )
        assertEquals(
            FieldReferenceStatus.INVALID_CONFIGURATION,
            resolve(
                sourceTemplate = sourceTemplate.copy(
                    fields = listOf(sourceField.copy(targetFieldId = "")),
                ),
            )?.status,
        )
        val selfField = sourceField.copy(
            id = targetField.id,
            targetCategory = " servers ",
            targetFieldId = targetField.id,
        )
        assertEquals(
            FieldReferenceStatus.INVALID_CONFIGURATION,
            resolve(
                field = sourceValue.copy(templateFieldId = selfField.id, value = "source-entry"),
                sourceTemplate = CategoryTemplate("Servers", listOf(selfField)),
            )?.status,
        )

        assertEquals(FieldReferenceStatus.MISSING, resolve(entries = emptyList())?.status)
        assertEquals(
            FieldReferenceStatus.MISSING,
            resolve(field = sourceValue.copy(value = "TARGET-ENTRY"))?.status,
        )
        assertEquals(
            FieldReferenceStatus.DELETED,
            resolve(
                templates = emptyList(),
                entries = listOf(targetEntry(category = "Archive", isDeleted = true)),
            )?.status,
        )
        assertEquals(
            FieldReferenceStatus.CATEGORY_MISMATCH,
            resolve(
                templates = emptyList(),
                entries = listOf(targetEntry(category = "Archive")),
            )?.status,
        )
        assertEquals(
            FieldReferenceStatus.TARGET_FIELD_MISSING,
            resolve(templates = emptyList())?.status,
        )
        assertEquals(
            FieldReferenceStatus.TARGET_FIELD_MISSING,
            resolve(
                templates = listOf(
                    targetTemplate.copy(fields = listOf(targetField.copy(id = "other-field"))),
                ),
            )?.status,
        )
        assertEquals(
            FieldReferenceStatus.TARGET_FIELD_UNSUPPORTED,
            resolve(
                templates = listOf(
                    targetTemplate.copy(
                        fields = listOf(targetField.copy(valueType = "fieldReference")),
                    ),
                ),
            )?.status,
        )
        assertEquals(
            FieldReferenceStatus.TARGET_FIELD_EMPTY,
            resolve(
                entries = listOf(
                    targetEntry(
                        customFields = listOf(
                            CustomField(
                                templateFieldId = "different-id",
                                name = targetField.name,
                                value = "name-fallback-must-not-resolve",
                            ),
                        ),
                    ),
                ),
            )?.status,
        )
        val blankValueResolution = resolve(
            entries = listOf(
                targetEntry(customFields = listOf(targetValue.copy(value = "   "))),
            ),
        )
        assertEquals(FieldReferenceStatus.TARGET_FIELD_EMPTY, blankValueResolution?.status)
        assertEquals("", blankValueResolution?.targetField?.value)
    }

    @Test
    fun resolvedProjectionIsMinimalAndOneHopOnly() {
        val resolution = resolve()

        assertEquals(FieldReferenceStatus.RESOLVED, resolution?.status)
        assertEquals(
            FieldReferenceTargetEntry(
                id = targetEntry.id,
                label = targetEntry.label,
                category = "Accounts",
            ),
            resolution?.targetEntry,
        )
        assertEquals(
            FieldReferenceTargetField(
                id = targetField.id,
                name = targetField.name,
                value = targetValue.value,
            ),
            resolution?.targetField,
        )

        val chainedTargetTemplate = targetTemplate.copy(
            fields = listOf(targetField.copy(valueType = "fieldReference")),
        )
        val chainedResolution = resolve(templates = listOf(chainedTargetTemplate))
        assertEquals(FieldReferenceStatus.TARGET_FIELD_UNSUPPORTED, chainedResolution?.status)
        assertEquals(
            FieldReferenceTargetField(
                id = targetField.id,
                name = targetField.name,
                value = "",
            ),
            chainedResolution?.targetField,
        )
    }

    @Test
    fun legacyEmptyTargetFieldIdFallsBackByNameButNonEmptyIdsNeverDo() {
        val legacyValue = targetValue.copy(
            templateFieldId = "",
            name = "  LOGIN ALIAS  ",
            value = "legacy-target-value",
        )
        val legacyResolution = resolve(
            entries = listOf(targetEntry(customFields = listOf(legacyValue))),
        )
        assertEquals(FieldReferenceStatus.RESOLVED, legacyResolution?.status)
        assertEquals("legacy-target-value", legacyResolution?.targetField?.value)

        listOf("wrong-target-id", "   ").forEach { incompatibleId ->
            val incompatibleValue = legacyValue.copy(templateFieldId = incompatibleId)
            assertEquals(
                FieldReferenceStatus.TARGET_FIELD_EMPTY,
                resolve(
                    entries = listOf(targetEntry(customFields = listOf(incompatibleValue))),
                )?.status,
            )
        }
    }

    @Test
    fun onlyExactFieldReferenceTypeIsRecognizedAndUiSemanticsAreSupported() {
        val wrongCaseTemplate = sourceTemplate.copy(
            fields = listOf(sourceField.copy(valueType = "FieldReference")),
        )

        assertNull(resolve(sourceTemplate = wrongCaseTemplate))
        assertTrue(isEditableCategoryFieldType("fieldReference"))
        assertEquals(
            CustomFieldSemantic.FIELD_REFERENCE,
            customFieldSemantics(sourceValue, sourceTemplate).semantic,
        )
    }

    @Test
    fun referencedTargetTextFieldsCanBeRenamedButNotDeletedOrRetyped() {
        val referencedIds = fieldReferenceTargetFieldIds(
            targetCategory = " accounts ",
            templates = listOf(
                sourceTemplate,
                sourceTemplate.copy(
                    category = "Other",
                    fields = listOf(
                        sourceField.copy(
                            id = "wrong-type",
                            valueType = "futureFieldReference",
                            targetFieldId = "ignored",
                        ),
                    ),
                ),
            ),
        )
        assertEquals(setOf(targetField.id), referencedIds)

        val renamed = categoryTemplateFieldsForUserSave(
            existing = listOf(targetField),
            requestedCustomFields = listOf(targetField.copy(name = "Login name")),
            referencedTargetFieldIds = referencedIds,
        )
        assertEquals(
            targetField.copy(name = "Login name"),
            renamed.single { field -> field.id == targetField.id },
        )

        val deletionAttempt = categoryTemplateFieldsForUserSave(
            existing = renamed,
            requestedCustomFields = emptyList(),
            referencedTargetFieldIds = referencedIds,
        )
        assertEquals(renamed, deletionAttempt)

        val typeChangeAttempt = categoryTemplateFieldsForUserSave(
            existing = renamed,
            requestedCustomFields = listOf(
                renamed.single { field -> field.id == targetField.id }
                    .copy(valueType = "entryReference"),
            ),
            referencedTargetFieldIds = referencedIds,
        )
        assertEquals(renamed, typeChangeAttempt)
    }

    private fun resolve(
        field: CustomField = sourceValue,
        sourceTemplate: CategoryTemplate = this.sourceTemplate,
        templates: List<CategoryTemplate> = listOf(targetTemplate),
        entries: List<VaultEntry> = listOf(targetEntry),
    ): FieldReferenceResolution? =
        resolveFieldReference(
            field = field,
            sourceTemplate = sourceTemplate,
            categoryTemplates = templates,
            entries = entries,
        )

    private val sourceField = FieldTemplate(
        id = "source-account-login",
        name = "Account login",
        valueType = "fieldReference",
        targetCategory = "Accounts",
        targetFieldId = "target-login",
    )
    private val targetField = FieldTemplate(
        id = "target-login",
        name = "Login alias",
    )
    private val sourceTemplate = CategoryTemplate("Servers", listOf(sourceField))
    private val targetTemplate = CategoryTemplate("Accounts", listOf(targetField))
    private val sourceValue = CustomField(
        id = "source-value",
        templateFieldId = sourceField.id,
        name = sourceField.name,
        value = "target-entry",
    )
    private val targetValue = CustomField(
        id = "target-value",
        templateFieldId = targetField.id,
        name = targetField.name,
        value = "private-target-value",
    )
    private val targetEntry = targetEntry(customFields = listOf(targetValue))

    private fun targetEntry(
        category: String = " Accounts ",
        customFields: List<CustomField> = listOf(targetValue),
        isDeleted: Boolean = false,
    ): VaultEntry = VaultEntry(
        id = "target-entry",
        label = "Target account",
        type = VaultEntryType.CREDENTIAL,
        payload = VaultPayload.Credential(
            CredentialPayload(
                password = "target-password-secret",
                category = category,
            ),
        ),
        customFields = customFields,
        isDeleted = isDeleted,
    )
}
