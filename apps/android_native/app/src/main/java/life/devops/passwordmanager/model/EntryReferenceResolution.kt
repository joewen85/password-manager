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
): EntryReferenceResolution? =
    resolveEntryReference(field, template) { targetId ->
        entries.firstOrNull { entry -> entry.id == targetId }
    }

private inline fun resolveEntryReference(
    field: CustomField,
    template: CategoryTemplate?,
    findTargetById: (String) -> VaultEntry?,
): EntryReferenceResolution? {
    val templateField = template.matchingReferenceTemplateField(field) ?: return null
    if (templateField.valueType != ENTRY_REFERENCE_VALUE_TYPE) return null
    if (field.value.isBlank()) {
        return EntryReferenceResolution(status = EntryReferenceStatus.EMPTY)
    }

    val targetEntry = findTargetById(field.value)
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

internal fun VaultEntry.withEntryReferenceSearchProjection(
    template: CategoryTemplate?,
    entriesById: Map<String, VaultEntry>,
): VaultEntry {
    val projectedFields = customFields.map { field ->
        val resolution = resolveEntryReference(field, template) { targetId ->
            entriesById[targetId]
        } ?: return@map field
        val searchableValue = if (resolution.status == EntryReferenceStatus.RESOLVED) {
            listOfNotNull(
                resolution.target?.label,
                resolution.target?.category?.takeIf { it.isNotEmpty() },
            ).joinToString(" ")
        } else {
            ""
        }
        field.copy(value = searchableValue)
    }
    return if (projectedFields == customFields) this else copy(customFields = projectedFields)
}

internal fun VaultEntry.remapEntryReferenceIds(
    idMap: Map<String, String>,
    template: CategoryTemplate?,
): VaultEntry {
    val remappedFields = customFields.map { field ->
        if (resolveEntryReference(field, template, emptyList()) == null) return@map field
        val destinationId = idMap[field.value] ?: return@map field
        field.copy(value = destinationId)
    }
    return if (remappedFields == customFields) this else copy(customFields = remappedFields)
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
