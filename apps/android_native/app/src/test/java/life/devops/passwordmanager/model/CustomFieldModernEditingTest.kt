package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class CustomFieldModernEditingTest {
    @Test
    fun modernMergeEditsTextAndReferencesWhilePreservingUnsupportedOriginals() {
        val template = categoryTemplate("Servers", "template-notes", "template-owner")
        val notes = CustomField(
            id = "notes-instance",
            templateFieldId = "template-notes",
            name = "Notes",
            value = "old notes",
        )
        val owner = CustomField(
            id = "owner-instance",
            templateFieldId = "template-owner",
            name = "Owner",
            value = "target-a",
        )
        val unknown = CustomField(
            id = "unknown-instance",
            templateFieldId = "template-future",
            name = "Future",
            value = "opaque-value",
        )
        val orphan = CustomField(
            id = "orphan-instance",
            templateFieldId = "missing-template",
            name = "Notes",
            value = "orphan-value",
        )
        val legacy = CustomField(id = "legacy-instance", name = "Ordinary", value = "remove me")

        val merged = mergeCustomFieldsForEditorSave(
            originalFields = listOf(notes, owner, unknown, orphan, legacy),
            editedFields = listOf(
                notes.copy(value = "new notes"),
                owner.copy(value = ""),
                unknown.copy(value = "tampered"),
                orphan.copy(value = "tampered"),
                CustomField(id = "new-legacy", name = "Region", value = "ap-south"),
                CustomField(
                    id = "new-unsupported",
                    templateFieldId = "missing-new-template",
                    name = "Unsupported",
                    value = "must-not-be-written",
                ),
            ),
            sourceTemplate = template,
        )

        assertEquals("new notes", merged.single { it.id == notes.id }.value)
        assertEquals("", merged.single { it.id == owner.id }.value)
        assertEquals(unknown, merged.single { it.id == unknown.id })
        assertEquals(orphan, merged.single { it.id == orphan.id })
        assertFalse(merged.any { it.id == legacy.id })
        assertEquals("ap-south", merged.single { it.id == "new-legacy" }.value)
        assertFalse(merged.any { it.id == "new-unsupported" })
    }

    @Test
    fun templateApplicationKeepsCategoryOwnedInstancesWithoutCrossCategoryValueReuse() {
        val templateA = categoryTemplate("A", "template-notes", "template-owner")
        val templateB = categoryTemplate("B", "template-notes", "template-owner")
        val initialA = applyCategoryTemplateToDraft(emptyList(), "A", templateA)
            .map { state ->
                state.copy(
                    field = state.field.copy(value = "A-${state.field.name}"),
                )
            }
        val repeatedA = applyCategoryTemplateToDraft(initialA, " a ", templateA)

        assertEquals(
            initialA.map { it.field.id to it.field.value },
            repeatedA.filterNot { it.isProtected }.map { it.field.id to it.field.value },
        )

        val switchedB = applyCategoryTemplateToDraft(repeatedA, "B", templateB)
        val activeA = switchedB.filter { it.sourceCategory.equals("A", ignoreCase = true) }
        val activeB = switchedB.filter { it.sourceCategory == "B" && !it.isProtected }
        assertTrue(activeA.all { it.isProtected })
        assertEquals(listOf("", ""), activeB.map { it.field.value })
        assertTrue(activeB.map { it.field.id }.none { id -> id in initialA.map { it.field.id } })
        assertNotEquals(
            initialA.single { it.field.templateFieldId == "template-owner" }.field.id,
            activeB.single { it.field.templateFieldId == "template-owner" }.field.id,
        )

        val withBValues = switchedB.map { state ->
            if (state.sourceCategory.equals("B", ignoreCase = true) && !state.isProtected) {
                state.copy(field = state.field.copy(value = "B-${state.field.name}"))
            } else {
                state
            }
        }
        val returnedA = applyCategoryTemplateToDraft(withBValues, "A", templateA)
        val restoredA = returnedA.filter {
            it.sourceCategory.equals("A", ignoreCase = true) && !it.isProtected
        }
        val protectedB = returnedA.filter { it.sourceCategory.equals("B", ignoreCase = true) }

        assertEquals(
            initialA.map { it.field.id to it.field.value },
            restoredA.map { it.field.id to it.field.value },
        )
        assertTrue(protectedB.all { it.isProtected })
        assertEquals(listOf("B-Notes", "B-Owner"), protectedB.map { it.field.value })
    }

    @Test
    fun categorySwitchMergeAcceptsDestinationFieldsAndReadbackDoesNotBleedLegacyIds() {
        val templateA = CategoryTemplate(
            category = "A",
            fields = categoryTemplate("A", "legacy-notes", "legacy-owner").fields +
                FieldTemplate(id = "future-a", name = "Future", valueType = "futureType"),
        )
        val templateB = categoryTemplate("B", "legacy-notes", "legacy-owner")
        val generatedA = applyCategoryTemplateToDraft(emptyList(), "A", templateA)
            .map { state -> state.copy(field = state.field.copy(value = "A-${state.field.name}")) }
        val unknown = CustomField(
            id = "unknown-a",
            templateFieldId = "future-a",
            name = "Future",
            value = "opaque-a",
        )
        val orphan = CustomField(
            id = "orphan-a",
            templateFieldId = "missing-a",
            name = "Orphan",
            value = "orphan-a-value",
        )
        val originalFields = generatedA.map { it.field } + unknown + orphan
        val initialStates = draftCustomFieldStates(originalFields, "A", templateA)
        val switchedB = applyCategoryTemplateToDraft(initialStates, "B", templateB)
            .map { state ->
                if (state.sourceCategory.equals("B", ignoreCase = true) && !state.isProtected) {
                    state.copy(field = state.field.copy(value = "B-${state.field.name}"))
                } else {
                    state
                }
            }

        val merged = mergeCustomFieldsForEditorSave(
            originalFields = originalFields,
            editedFields = switchedB.map { it.field },
            sourceTemplate = templateA,
            destinationTemplate = templateB,
            protectedFieldIds = switchedB.filter { it.isProtected }.mapTo(mutableSetOf()) { it.field.id },
        )
        val readback = draftCustomFieldStates(merged, "B", templateB)
        val activeReadback = readback.filterNot { it.isProtected }

        assertEquals(listOf("B-Notes", "B-Owner"), activeReadback.map { it.field.value })
        assertTrue(activeReadback.none { state -> state.field.value.startsWith("A-") })
        assertEquals(unknown, merged.single { it.id == unknown.id })
        assertEquals(orphan, merged.single { it.id == orphan.id })
        assertTrue(readback.single { it.field.id == unknown.id }.isProtected)
        assertTrue(readback.single { it.field.id == orphan.id }.isProtected)
    }

    private fun categoryTemplate(
        category: String,
        textFieldId: String,
        referenceFieldId: String,
    ): CategoryTemplate = CategoryTemplate(
        category = category,
        fields = listOf(
            FieldTemplate(id = textFieldId, name = "Notes"),
            FieldTemplate(
                id = referenceFieldId,
                name = "Owner",
                valueType = "entryReference",
                targetCategory = "Accounts",
            ),
        ),
    )
}
