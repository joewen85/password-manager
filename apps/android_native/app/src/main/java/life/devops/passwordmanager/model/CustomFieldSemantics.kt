package life.devops.passwordmanager.model

internal enum class CustomFieldSemantic {
    TEXT,
    ENTRY_REFERENCE,
    FIELD_REFERENCE,
    UNSUPPORTED,
}

internal data class CustomFieldSemantics(
    val semantic: CustomFieldSemantic,
    val templateField: FieldTemplate? = null,
)

internal fun customFieldSemantics(
    field: CustomField,
    template: CategoryTemplate?,
): CustomFieldSemantics {
    val templateField = matchingCustomFieldTemplate(field, template)
    if (templateField == null) {
        return CustomFieldSemantics(
            semantic = if (field.templateFieldId.isEmpty()) {
                CustomFieldSemantic.TEXT
            } else {
                CustomFieldSemantic.UNSUPPORTED
            },
        )
    }
    val semantic = when (templateField.normalizedValueType()) {
        CUSTOM_FIELD_TEXT_VALUE_TYPE -> CustomFieldSemantic.TEXT
        CUSTOM_FIELD_ENTRY_REFERENCE_VALUE_TYPE -> CustomFieldSemantic.ENTRY_REFERENCE
        CUSTOM_FIELD_REFERENCE_VALUE_TYPE -> CustomFieldSemantic.FIELD_REFERENCE
        else -> CustomFieldSemantic.UNSUPPORTED
    }
    return CustomFieldSemantics(
        semantic = semantic,
        templateField = templateField,
    )
}

internal fun canExposeRawCustomFieldValue(
    field: CustomField,
    template: CategoryTemplate?,
): Boolean = customFieldSemantics(field, template).semantic == CustomFieldSemantic.TEXT

internal fun matchingCustomFieldTemplate(
    field: CustomField,
    template: CategoryTemplate?,
): FieldTemplate? {
    val templateFields = template?.fields ?: return null
    if (field.templateFieldId.isNotEmpty()) {
        return templateFields.firstOrNull { templateField ->
            templateField.id == field.templateFieldId
        }
    }

    val normalizedName = field.name.trim()
    if (normalizedName.isEmpty()) return null
    return templateFields.firstOrNull { templateField ->
        templateField.name.trim().equals(normalizedName, ignoreCase = true)
    }
}

internal fun FieldTemplate.normalizedValueType(): String =
    valueType.takeUnless { it.isBlank() } ?: CUSTOM_FIELD_TEXT_VALUE_TYPE

internal const val CUSTOM_FIELD_TEXT_VALUE_TYPE = "text"
internal const val CUSTOM_FIELD_ENTRY_REFERENCE_VALUE_TYPE = "entryReference"
internal const val CUSTOM_FIELD_REFERENCE_VALUE_TYPE = "fieldReference"
