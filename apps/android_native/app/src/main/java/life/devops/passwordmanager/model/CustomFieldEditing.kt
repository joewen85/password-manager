package life.devops.passwordmanager.model

internal fun templateCustomFields(template: CategoryTemplate?): MutableList<CustomField> {
    val seen = mutableSetOf<String>()
    return (template?.fields ?: CategoryTemplate.defaultCategoryFields())
        .asSequence()
        .filter { field -> field.valueType == "text" }
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
            generated.templateFieldId.isNotBlank() &&
                field.templateFieldId == generated.templateFieldId
        } ?: currentFields.firstOrNull { field ->
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
    fields.filter { field -> template.isTextField(field) }.toMutableList()

internal fun mergeCustomFieldsForLegacyEditorSave(
    originalFields: List<CustomField>,
    editedFields: List<CustomField>,
    template: CategoryTemplate?,
): List<CustomField> {
    val protectedFields = originalFields.filterNot { field -> template.isTextField(field) }
    val protectedIds = protectedFields.mapTo(mutableSetOf()) { field -> field.id }
    val remainingEdited = editedFields
        .filterNot { field -> field.id in protectedIds }
        .filter { field -> template.isTextField(field) }
        .toMutableList()
    val merged = mutableListOf<CustomField>()

    originalFields.forEach { original ->
        if (!template.isTextField(original)) {
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

private fun CategoryTemplate?.isTextField(field: CustomField): Boolean =
    matchingField(field)?.valueType?.let { valueType -> valueType == "text" } ?: true

private fun CategoryTemplate?.matchingField(field: CustomField): FieldTemplate? {
    val templateFields = this?.fields ?: return null
    val byId = field.templateFieldId
        .takeIf { id -> id.isNotBlank() }
        ?.let { id -> templateFields.firstOrNull { templateField -> templateField.id == id } }
    if (byId != null) return byId

    val normalizedName = field.name.trim()
    if (normalizedName.isEmpty()) return null
    return templateFields.firstOrNull { templateField ->
        templateField.name.trim().equals(normalizedName, ignoreCase = true)
    }
}
