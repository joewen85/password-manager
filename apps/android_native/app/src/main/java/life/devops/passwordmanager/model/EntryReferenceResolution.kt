package life.devops.passwordmanager.model

internal enum class EntryReferenceStatus {
    EMPTY,
    RESOLVED,
    MISSING,
    DELETED,
    CATEGORY_MISMATCH,
}

internal data class EntryReferenceTarget(
    val id: String,
    val label: String,
    val category: String,
)

internal data class EntryReferenceResolution(
    val status: EntryReferenceStatus,
    val target: EntryReferenceTarget? = null,
)

internal fun resolveEntryReference(
    field: CustomField,
    template: CategoryTemplate?,
    entries: List<VaultEntry>,
): EntryReferenceResolution? {
    val templateField = template.matchingReferenceTemplateField(field) ?: return null
    if (templateField.valueType != ENTRY_REFERENCE_VALUE_TYPE) return null
    if (field.value.isBlank()) {
        return EntryReferenceResolution(status = EntryReferenceStatus.EMPTY)
    }

    val targetEntry = entries.firstOrNull { entry -> entry.id == field.value }
        ?: return EntryReferenceResolution(status = EntryReferenceStatus.MISSING)
    val target = EntryReferenceTarget(
        id = targetEntry.id,
        label = targetEntry.label,
        category = targetEntry.payload.category.trim(),
    )
    if (targetEntry.isDeleted) {
        return EntryReferenceResolution(
            status = EntryReferenceStatus.DELETED,
            target = target,
        )
    }

    val targetCategory = templateField.targetCategory.trim()
    if (
        targetCategory.isNotEmpty() &&
        !target.category.equals(targetCategory, ignoreCase = true)
    ) {
        return EntryReferenceResolution(
            status = EntryReferenceStatus.CATEGORY_MISMATCH,
            target = target,
        )
    }
    return EntryReferenceResolution(
        status = EntryReferenceStatus.RESOLVED,
        target = target,
    )
}

private fun CategoryTemplate?.matchingReferenceTemplateField(field: CustomField): FieldTemplate? {
    val templateFields = this?.fields ?: return null
    if (field.templateFieldId.isNotEmpty()) {
        return templateFields.firstOrNull { templateField ->
            templateField.id == field.templateFieldId
        }
    }

    val fieldName = field.name.trim()
    if (fieldName.isEmpty()) return null
    return templateFields.firstOrNull { templateField ->
        templateField.name.trim().equals(fieldName, ignoreCase = true)
    }
}

private const val ENTRY_REFERENCE_VALUE_TYPE = "entryReference"
