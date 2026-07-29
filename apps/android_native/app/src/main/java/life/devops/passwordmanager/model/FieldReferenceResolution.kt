package life.devops.passwordmanager.model

internal enum class FieldReferenceStatus {
    EMPTY,
    INVALID_CONFIGURATION,
    MISSING,
    DELETED,
    CATEGORY_MISMATCH,
    TARGET_FIELD_MISSING,
    TARGET_FIELD_UNSUPPORTED,
    TARGET_FIELD_EMPTY,
    RESOLVED,
}

internal data class FieldReferenceTargetEntry(
    val id: String,
    val label: String,
    val category: String,
)

internal data class FieldReferenceTargetField(
    val id: String,
    val name: String,
    val value: String,
)

internal data class FieldReferenceResolution(
    val status: FieldReferenceStatus,
    val targetEntry: FieldReferenceTargetEntry? = null,
    val targetField: FieldReferenceTargetField? = null,
)

internal fun resolveFieldReference(
    field: CustomField,
    sourceTemplate: CategoryTemplate?,
    categoryTemplates: Collection<CategoryTemplate>,
    entries: Collection<VaultEntry>,
): FieldReferenceResolution? =
    resolveFieldReference(
        field = field,
        sourceTemplate = sourceTemplate,
        findTargetById = { targetId -> entries.firstOrNull { entry -> entry.id == targetId } },
        findTemplateByCategory = { targetCategory ->
            categoryTemplates.firstOrNull { template ->
                template.category.trim().equals(targetCategory, ignoreCase = true)
            }
        },
    )

internal fun resolveFieldReference(
    field: CustomField,
    sourceTemplate: CategoryTemplate?,
    categoryTemplatesByName: Map<String, CategoryTemplate>,
    entriesById: Map<String, VaultEntry>,
): FieldReferenceResolution? =
    resolveFieldReference(
        field = field,
        sourceTemplate = sourceTemplate,
        findTargetById = entriesById::get,
        findTemplateByCategory = { category -> categoryTemplatesByName[category.lowercase()] },
    )

private inline fun resolveFieldReference(
    field: CustomField,
    sourceTemplate: CategoryTemplate?,
    findTargetById: (String) -> VaultEntry?,
    findTemplateByCategory: (String) -> CategoryTemplate?,
): FieldReferenceResolution? {
    val sourceTemplateField = fieldReferenceTemplateField(field, sourceTemplate) ?: return null
    if (field.value.isBlank()) {
        return FieldReferenceResolution(status = FieldReferenceStatus.EMPTY)
    }

    val targetCategory = sourceTemplateField.targetCategory.trim()
    val targetFieldId = sourceTemplateField.targetFieldId
    if (
        targetCategory.isEmpty() ||
        targetFieldId.isBlank() ||
        (
            sourceTemplate?.category.orEmpty().trim().equals(targetCategory, ignoreCase = true) &&
                sourceTemplateField.id == targetFieldId
        )
    ) {
        return FieldReferenceResolution(status = FieldReferenceStatus.INVALID_CONFIGURATION)
    }

    val target = findTargetById(field.value)
        ?: return FieldReferenceResolution(status = FieldReferenceStatus.MISSING)
    val targetEntry = FieldReferenceTargetEntry(
        id = target.id,
        label = target.label,
        category = target.payload.category.trim(),
    )
    if (target.isDeleted) {
        return FieldReferenceResolution(
            status = FieldReferenceStatus.DELETED,
            targetEntry = targetEntry,
        )
    }
    if (!targetEntry.category.equals(targetCategory, ignoreCase = true)) {
        return FieldReferenceResolution(
            status = FieldReferenceStatus.CATEGORY_MISMATCH,
            targetEntry = targetEntry,
        )
    }

    val targetTemplate = findTemplateByCategory(targetCategory)
        ?: return FieldReferenceResolution(
            status = FieldReferenceStatus.TARGET_FIELD_MISSING,
            targetEntry = targetEntry,
        )
    val targetTemplateField = targetTemplate.fields.firstOrNull { templateField ->
        templateField.id == targetFieldId
    } ?: return FieldReferenceResolution(
        status = FieldReferenceStatus.TARGET_FIELD_MISSING,
        targetEntry = targetEntry,
    )
    val targetField = FieldReferenceTargetField(
        id = targetTemplateField.id,
        name = targetTemplateField.name.trim(),
        value = "",
    )
    if (targetTemplateField.normalizedValueType() != CUSTOM_FIELD_TEXT_VALUE_TYPE) {
        return FieldReferenceResolution(
            status = FieldReferenceStatus.TARGET_FIELD_UNSUPPORTED,
            targetEntry = targetEntry,
            targetField = targetField,
        )
    }
    if (targetTemplateField.isBuiltInEntryNameField()) {
        if (target.label.isBlank()) {
            return FieldReferenceResolution(
                status = FieldReferenceStatus.TARGET_FIELD_EMPTY,
                targetEntry = targetEntry,
                targetField = targetField,
            )
        }
        return FieldReferenceResolution(
            status = FieldReferenceStatus.RESOLVED,
            targetEntry = targetEntry,
            targetField = targetField.copy(value = target.label),
        )
    }

    val targetValue = matchingTargetFieldValue(target, targetTemplateField)
    if (targetValue == null || targetValue.value.isBlank()) {
        return FieldReferenceResolution(
            status = FieldReferenceStatus.TARGET_FIELD_EMPTY,
            targetEntry = targetEntry,
            targetField = targetField,
        )
    }
    return FieldReferenceResolution(
        status = FieldReferenceStatus.RESOLVED,
        targetEntry = targetEntry,
        targetField = targetField.copy(value = targetValue.value),
    )
}

internal fun isFieldReference(
    field: CustomField,
    sourceTemplate: CategoryTemplate?,
): Boolean = fieldReferenceTemplateField(field, sourceTemplate) != null

private fun matchingTargetFieldValue(
    target: VaultEntry,
    targetTemplateField: FieldTemplate,
): CustomField? =
    target.customFields.firstOrNull { customField ->
        customField.templateFieldId.isNotEmpty() &&
            customField.templateFieldId == targetTemplateField.id
    } ?: target.customFields.firstOrNull { customField ->
        customField.templateFieldId.isEmpty() &&
            customField.name.trim().isNotEmpty() &&
            customField.name.trim().equals(targetTemplateField.name.trim(), ignoreCase = true)
    }

private fun FieldTemplate.isBuiltInEntryNameField(): Boolean =
    id == CategoryTemplate.stableFieldId("名称") || name.trim() == "名称"

private fun fieldReferenceTemplateField(
    field: CustomField,
    sourceTemplate: CategoryTemplate?,
): FieldTemplate? {
    val templateField = matchingCustomFieldTemplate(field, sourceTemplate) ?: return null
    return templateField.takeIf { it.valueType == FIELD_REFERENCE_VALUE_TYPE }
}

internal const val FIELD_REFERENCE_VALUE_TYPE = "fieldReference"
