package life.devops.passwordmanager.model

import java.util.UUID

private const val TEXT_VALUE_TYPE = "text"
private const val ENTRY_REFERENCE_VALUE_TYPE = "entryReference"

internal fun isEditableCategoryFieldType(valueType: String?): Boolean =
    when (normalizedCategoryFieldValueType(valueType)) {
        TEXT_VALUE_TYPE, ENTRY_REFERENCE_VALUE_TYPE -> true
        else -> false
    }

internal fun categoryTemplateFieldsForUserSave(
    existing: List<FieldTemplate>,
    requestedCustomFields: List<FieldTemplate>,
    storedValueFieldIds: Set<String> = emptySet(),
    referencedTargetFieldIds: Set<String> = emptySet(),
): List<FieldTemplate> {
    val requested = CategoryTemplate.defaultCategoryFields() + requestedCustomFields
    val usedExistingIndexes = mutableSetOf<Int>()
    val merged = mutableListOf<FieldTemplate>()

    requested.forEach { field ->
        val existingIndex = matchingExistingFieldIndex(existing, field, usedExistingIndexes)
        if (existingIndex < 0) {
            merged += normalizedCategoryTemplateField(field)
            return@forEach
        }

        usedExistingIndexes += existingIndex
        val current = existing[existingIndex]
        val isReferencedTextTarget =
            current.id in referencedTargetFieldIds &&
                normalizedCategoryFieldValueType(current.valueType) == TEXT_VALUE_TYPE
        when {
            !isEditableCategoryFieldType(current.valueType) -> merged += current
            (current.id in storedValueFieldIds || isReferencedTextTarget) &&
                normalizedCategoryFieldValueType(current.valueType) !=
                normalizedCategoryFieldValueType(field.valueType) -> merged += current
            else -> merged += normalizedCategoryTemplateField(field).copy(id = current.id)
        }
    }

    existing.forEachIndexed { index, field ->
        if (
            index !in usedExistingIndexes &&
            (
                !isEditableCategoryFieldType(field.valueType) ||
                    field.id in storedValueFieldIds ||
                    (
                        field.id in referencedTargetFieldIds &&
                            normalizedCategoryFieldValueType(field.valueType) == TEXT_VALUE_TYPE
                    )
            )
        ) {
            merged += field
        }
    }
    return merged
}

internal fun fieldReferenceTargetFieldIds(
    targetCategory: String,
    templates: Collection<CategoryTemplate>,
): Set<String> {
    val normalizedTargetCategory = targetCategory.trim()
    if (normalizedTargetCategory.isEmpty()) return emptySet()
    return buildSet {
        templates.forEach { template ->
            template.fields.forEach { field ->
                if (
                    field.valueType == FIELD_REFERENCE_VALUE_TYPE &&
                    field.targetCategory.trim().equals(normalizedTargetCategory, ignoreCase = true) &&
                    field.targetFieldId.isNotBlank()
                ) {
                    add(field.targetFieldId)
                }
            }
        }
    }
}

internal fun newCategoryTemplateField(
    name: String = "",
    valueType: String = TEXT_VALUE_TYPE,
    targetCategory: String = "",
): FieldTemplate =
    normalizedCategoryTemplateField(
        FieldTemplate(
            id = UUID.randomUUID().toString(),
            name = name,
            valueType = valueType,
            targetCategory = targetCategory,
        )
    )

private fun matchingExistingFieldIndex(
    existing: List<FieldTemplate>,
    requested: FieldTemplate,
    usedIndexes: Set<Int>,
): Int {
    if (requested.id.isNotEmpty()) {
        val idMatch = existing.indexOfFirst { index, field ->
            index !in usedIndexes && field.id == requested.id
        }
        if (idMatch >= 0) return idMatch
    }

    val requestedName = requested.name.trim()
    if (requestedName.isEmpty()) return -1
    return existing.indexOfFirst { index, field ->
        index !in usedIndexes && field.name.trim().equals(requestedName, ignoreCase = true)
    }
}

private inline fun <T> List<T>.indexOfFirst(predicate: (Int, T) -> Boolean): Int {
    forEachIndexed { index, value ->
        if (predicate(index, value)) return index
    }
    return -1
}

private fun normalizedCategoryTemplateField(field: FieldTemplate): FieldTemplate {
    val valueType = normalizedCategoryFieldValueType(field.valueType)
    val targetCategory = when (valueType) {
        TEXT_VALUE_TYPE -> ""
        ENTRY_REFERENCE_VALUE_TYPE -> field.targetCategory.trim()
        else -> field.targetCategory
    }
    return field.copy(
        name = field.name.trim(),
        valueType = valueType,
        targetCategory = targetCategory,
    )
}

private fun normalizedCategoryFieldValueType(valueType: String?): String =
    valueType?.takeIf { it.isNotBlank() } ?: TEXT_VALUE_TYPE
