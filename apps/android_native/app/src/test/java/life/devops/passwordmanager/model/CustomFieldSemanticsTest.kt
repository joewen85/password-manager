package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CustomFieldSemanticsTest {
    @Test
    fun boundFieldsUseOnlyExactOpaqueTemplateIds() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-notes", name = "Notes"),
                FieldTemplate(id = "   ", name = "Whitespace", valueType = "entryReference"),
            ),
        )

        val exact = customFieldSemantics(
            CustomField(templateFieldId = "template-notes", name = "Renamed"),
            template,
        )
        val orphanWithMatchingName = customFieldSemantics(
            CustomField(templateFieldId = "missing-template", name = "Notes"),
            template,
        )
        val exactWhitespace = customFieldSemantics(
            CustomField(templateFieldId = "   ", name = "Anything"),
            template,
        )

        assertEquals(CustomFieldSemantic.TEXT, exact.semantic)
        assertEquals("template-notes", exact.templateField?.id)
        assertEquals(CustomFieldSemantic.UNSUPPORTED, orphanWithMatchingName.semantic)
        assertNull(orphanWithMatchingName.templateField)
        assertEquals(CustomFieldSemantic.ENTRY_REFERENCE, exactWhitespace.semantic)
    }

    @Test
    fun trulyUnboundLegacyFieldsRemainTextUnlessTheirNameMatchesADeclaredType() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "template-owner", name = "Owner", valueType = "entryReference"),
                FieldTemplate(id = "template-future", name = "Future", valueType = "futureType"),
            ),
        )

        assertEquals(
            CustomFieldSemantic.TEXT,
            customFieldSemantics(CustomField(name = "Ordinary"), template).semantic,
        )
        assertEquals(
            CustomFieldSemantic.ENTRY_REFERENCE,
            customFieldSemantics(CustomField(name = " owner "), template).semantic,
        )
        assertEquals(
            CustomFieldSemantic.UNSUPPORTED,
            customFieldSemantics(CustomField(name = "future"), template).semantic,
        )
    }

    @Test
    fun blankValueTypesAreTextAndUnknownValueTypesAreUnsupported() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(id = "blank", name = "Blank", valueType = "   "),
                FieldTemplate(id = "unknown", name = "Unknown", valueType = "futureType"),
            ),
        )
        val blank = CustomField(templateFieldId = "blank", name = "Blank", value = "visible")
        val unknown = CustomField(templateFieldId = "unknown", name = "Unknown", value = "opaque")

        assertEquals(CustomFieldSemantic.TEXT, customFieldSemantics(blank, template).semantic)
        assertEquals(CustomFieldSemantic.UNSUPPORTED, customFieldSemantics(unknown, template).semantic)
        assertTrue(canExposeRawCustomFieldValue(blank, template))
        assertFalse(canExposeRawCustomFieldValue(unknown, template))
    }

    @Test
    fun fieldReferencesHaveDedicatedSemanticsAndNeverExposeRawEntryIds() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(
                    id = "template-owner-email",
                    name = "Owner email",
                    valueType = "fieldReference",
                    targetCategory = "Accounts",
                    targetFieldId = "account-email",
                ),
            ),
        )
        val field = CustomField(
            templateFieldId = "template-owner-email",
            name = "Owner email",
            value = "opaque-entry-id",
        )

        assertEquals(CustomFieldSemantic.FIELD_REFERENCE, customFieldSemantics(field, template).semantic)
        assertFalse(canExposeRawCustomFieldValue(field, template))
    }
}
