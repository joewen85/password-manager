package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals

class CustomFieldEditingTest {
    @Test
    fun templateFieldsCreateOnlyTextEditorsWithStableBindings() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-name", name = "名称"),
                FieldTemplate(id = "template-notes", name = "Notes"),
                FieldTemplate(
                    id = "template-owner",
                    name = "Owner",
                    valueType = "entryReference",
                    targetCategory = "Accounts",
                ),
                FieldTemplate(id = "template-future", name = "Future", valueType = "futureType"),
            ),
        )

        val fields = templateCustomFields(template)

        assertEquals(listOf("Notes"), fields.map { field -> field.name })
        assertEquals(listOf("template-notes"), fields.map { field -> field.templateFieldId })
    }

    @Test
    fun categorySwitchMatchesTextValuesByTemplateIdBeforeLegacyName() {
        val fields = mutableListOf(
            CustomField(
                id = "field-by-id",
                templateFieldId = "template-notes",
                name = "Old Notes Name",
                value = "kept by id",
            ),
            CustomField(id = "field-by-name", name = "Region", value = "kept by name"),
        )
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-notes", name = "Notes"),
                FieldTemplate(id = "template-region", name = "Region"),
                FieldTemplate(id = "template-owner", name = "Owner", valueType = "entryReference"),
            ),
        )

        fields.replaceWithTemplate(template)

        assertEquals(listOf("template-notes", "template-region"), fields.map { it.templateFieldId })
        assertEquals(listOf("kept by id", "kept by name"), fields.map { it.value })
    }

    @Test
    fun legacyEditorHidesRecognizedNonTextFieldsAndKeepsTextFieldsEditable() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-notes", name = "Notes"),
                FieldTemplate(id = "template-owner", name = "Owner", valueType = "entryReference"),
                FieldTemplate(id = "template-future", name = "Future", valueType = "futureType"),
            ),
        )
        val fields = listOf(
            CustomField(id = "notes", templateFieldId = "template-notes", name = "Notes", value = "editable"),
            CustomField(id = "owner", templateFieldId = "template-owner", name = "Owner", value = "target"),
            CustomField(id = "future", name = "Future", value = "opaque"),
            CustomField(id = "custom", name = "Ordinary", value = "editable custom"),
        )

        val editable = editableCustomFieldsForLegacyEditor(fields, template)

        assertEquals(listOf("notes", "custom"), editable.map { field -> field.id })
    }

    @Test
    fun legacyEditorSaveRestoresCompleteNonTextFieldsWhileApplyingTextEdits() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-notes", name = "Notes"),
                FieldTemplate(id = "template-owner", name = "Owner", valueType = "entryReference"),
                FieldTemplate(id = "template-future", name = "Future", valueType = "futureType"),
            ),
        )
        val owner = CustomField(
            id = "owner-instance",
            templateFieldId = "template-owner",
            name = " Owner ",
            value = " target-id ",
        )
        val future = CustomField(
            id = "future-instance",
            templateFieldId = "template-future",
            name = "Future",
            value = "opaque-value",
        )
        val notes = CustomField(
            id = "notes-instance",
            templateFieldId = "template-notes",
            name = "Notes",
            value = "old text",
        )

        val merged = mergeCustomFieldsForLegacyEditorSave(
            originalFields = listOf(owner, future, notes),
            editedFields = listOf(notes.copy(value = "new text")),
            template = template,
        )

        assertEquals(listOf(owner, future, notes.copy(value = "new text")), merged)
    }

    @Test
    fun categoryTemplateDraftIncludesLegacyAndFieldReferencesWithoutExposingThemAsText() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-notes", name = "Notes"),
                FieldTemplate(
                    id = "template-owner",
                    name = "Legacy owner",
                    valueType = "entryReference",
                    targetCategory = "Accounts",
                ),
                FieldTemplate(
                    id = "template-owner-email",
                    name = "Owner email",
                    valueType = "fieldReference",
                    targetCategory = "Accounts",
                    targetFieldId = "account-email",
                ),
            ),
        )

        val states = applyCategoryTemplateToDraft(
            states = emptyList(),
            targetCategory = "Servers",
            template = template,
        )

        assertEquals(
            listOf("template-notes", "template-owner", "template-owner-email"),
            states.map { state -> state.field.templateFieldId },
        )
        assertEquals(
            listOf(
                CustomFieldSemantic.TEXT,
                CustomFieldSemantic.ENTRY_REFERENCE,
                CustomFieldSemantic.FIELD_REFERENCE,
            ),
            states.map { state -> customFieldSemantics(state.field, template).semantic },
        )
    }
}
