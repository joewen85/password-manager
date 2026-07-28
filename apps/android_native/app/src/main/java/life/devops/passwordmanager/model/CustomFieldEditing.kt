package life.devops.passwordmanager.model

internal fun templateCustomFields(template: CategoryTemplate?): MutableList<CustomField> {
    val seen = mutableSetOf<String>()
    return (template?.fields ?: CategoryTemplate.defaultCategoryFields())
        .asSequence()
        .filter { field -> field.normalizedValueType() == CUSTOM_FIELD_TEXT_VALUE_TYPE }
        .mapNotNull { field ->
            val name = field.name.trim()
            val key = name.lowercase()
            if (name.isEmpty() || key == "名称" || !seen.add(key)) {
                null
            } else {
                CustomField(
                    templateFieldId = field.id,
                    name = name,
                )
            }
        }
        .toMutableList()
}

internal fun MutableList<CustomField>.replaceWithTemplate(template: CategoryTemplate?) {
    val currentFields = toList()
    val nextFields = templateCustomFields(template).map { generated ->
        val existing = currentFields.firstOrNull { field ->
            generated.templateFieldId.isNotEmpty() &&
                field.templateFieldId == generated.templateFieldId
        } ?: currentFields.firstOrNull { field ->
            field.templateFieldId.isEmpty() &&
            field.name.trim().equals(generated.name.trim(), ignoreCase = true)
        }
        generated.copy(value = existing?.value.orEmpty())
    }
    clear()
    addAll(nextFields)
}

internal fun editableCustomFieldsForLegacyEditor(
    fields: List<CustomField>,
    template: CategoryTemplate?,
): MutableList<CustomField> =
    fields.filter { field -> canExposeRawCustomFieldValue(field, template) }.toMutableList()

internal fun mergeCustomFieldsForLegacyEditorSave(
    originalFields: List<CustomField>,
    editedFields: List<CustomField>,
    template: CategoryTemplate?,
): List<CustomField> {
    val protectedFields = originalFields.filter { field ->
        customFieldSemantics(field, template).semantic != CustomFieldSemantic.TEXT
    }
    val protectedIds = protectedFields.mapTo(mutableSetOf()) { field -> field.id }
    val remainingEdited = editedFields
        .filterNot { field -> field.id in protectedIds }
        .filter { field ->
            customFieldSemantics(field, template).semantic == CustomFieldSemantic.TEXT
        }
        .toMutableList()
    val merged = mutableListOf<CustomField>()

    originalFields.forEach { original ->
        if (customFieldSemantics(original, template).semantic != CustomFieldSemantic.TEXT) {
            merged += original
            return@forEach
        }
        val editedIndex = remainingEdited.indexOfFirst { field -> field.id == original.id }
        if (editedIndex >= 0) {
            merged += remainingEdited.removeAt(editedIndex)
        }
    }
    merged += remainingEdited
    return merged
}

internal fun mergeCustomFieldsForEditorSave(
    originalFields: List<CustomField>,
    editedFields: List<CustomField>,
    sourceTemplate: CategoryTemplate?,
    destinationTemplate: CategoryTemplate? = sourceTemplate,
    protectedFieldIds: Set<String> = emptySet(),
): List<CustomField> {
    val protectedFields = originalFields.filter { field ->
        customFieldSemantics(field, sourceTemplate).semantic == CustomFieldSemantic.UNSUPPORTED
    }
    val protectedIds = protectedFields.mapTo(mutableSetOf()) { field -> field.id }
    val remainingEdited = editedFields
        .filterNot { field -> field.id in protectedIds }
        .filterNot { field -> field.id in protectedFieldIds }
        .filter { field ->
            customFieldSemantics(field, destinationTemplate).semantic != CustomFieldSemantic.UNSUPPORTED
        }
        .toMutableList()
    val merged = mutableListOf<CustomField>()

    originalFields.forEach { original ->
        val semantics = customFieldSemantics(original, sourceTemplate)
        if (semantics.semantic == CustomFieldSemantic.UNSUPPORTED) {
            merged += original
            return@forEach
        }
        val editedIndex = remainingEdited.indexOfFirst { field -> field.id == original.id }
        if (editedIndex >= 0) {
            merged += remainingEdited.removeAt(editedIndex)
        }
    }
    merged += remainingEdited
    return merged
}

internal data class DraftCustomFieldState(
    val field: CustomField,
    val sourceCategory: String,
    val isProtected: Boolean,
)

internal fun draftCustomFieldStates(
    fields: List<CustomField>,
    sourceCategory: String,
    template: CategoryTemplate?,
): List<DraftCustomFieldState> = fields.map { field ->
    DraftCustomFieldState(
        field = field,
        sourceCategory = sourceCategory.trim(),
        isProtected = customFieldSemantics(field, template).semantic == CustomFieldSemantic.UNSUPPORTED,
    )
}

internal fun applyCategoryTemplateToDraft(
    states: List<DraftCustomFieldState>,
    targetCategory: String,
    template: CategoryTemplate?,
): List<DraftCustomFieldState> {
    val category = targetCategory.trim()
    val usedIndexes = mutableSetOf<Int>()
    val seenNames = mutableSetOf<String>()
    val nextStates = mutableListOf<DraftCustomFieldState>()
    val templateFields = template?.fields ?: CategoryTemplate.defaultCategoryFields()

    templateFields.forEach { templateField ->
        val semantic = templateField.normalizedValueType()
        if (
            semantic != CUSTOM_FIELD_TEXT_VALUE_TYPE &&
            semantic != CUSTOM_FIELD_ENTRY_REFERENCE_VALUE_TYPE
        ) {
            return@forEach
        }
        val name = templateField.name.trim()
        val nameKey = name.lowercase()
        if (name.isEmpty() || nameKey == "名称" || !seenNames.add(nameKey)) {
            return@forEach
        }
        val existingIndex = states.indices.firstOrNull { index ->
            val state = states[index]
            index !in usedIndexes &&
                sameCategory(state.sourceCategory, category) &&
                state.field.matchesTemplateField(templateField)
        } ?: -1
        val existing = states.getOrNull(existingIndex)
        if (existingIndex >= 0) {
            usedIndexes += existingIndex
        }
        val field = existing?.field?.copy(
            templateFieldId = templateField.id,
            name = name,
        ) ?: CustomField(
            templateFieldId = templateField.id,
            name = name,
        )
        nextStates += DraftCustomFieldState(
            field = field,
            sourceCategory = category,
            isProtected = false,
        )
    }

    states.forEachIndexed { index, state ->
        if (index in usedIndexes) return@forEachIndexed
        val belongsToTarget = sameCategory(state.sourceCategory, category)
        val semantic = customFieldSemantics(state.field, template).semantic
        nextStates += state.copy(
            isProtected = !belongsToTarget || semantic == CustomFieldSemantic.UNSUPPORTED,
        )
    }
    return nextStates
}

private fun CustomField.matchesTemplateField(templateField: FieldTemplate): Boolean =
    if (templateFieldId.isNotEmpty()) {
        templateFieldId == templateField.id
    } else {
        name.trim().equals(templateField.name.trim(), ignoreCase = true)
    }

private fun sameCategory(left: String, right: String): Boolean =
    left.trim().equals(right.trim(), ignoreCase = true)
