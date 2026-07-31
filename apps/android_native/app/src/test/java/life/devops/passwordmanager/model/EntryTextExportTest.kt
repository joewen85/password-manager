package life.devops.passwordmanager.model

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class EntryTextExportTest {
    @Test
    fun selectedFieldsRenderAsOrderedKeyValueLinesWithoutReferenceIds() {
        val targetFieldId = "target-ip"
        val entryReferenceFieldId = "owner-reference"
        val fieldReferenceFieldId = "ip-reference"
        val target = VaultEntry(
            id = "target-entry",
            label = "Target Server",
            type = VaultEntryType.SERVER,
            payload = VaultPayload.Server(ServerPayload(category = "Targets")),
            customFields = listOf(
                CustomField(name = "IP", value = "10.0.0.8", templateFieldId = targetFieldId),
            ),
        )
        val entry = VaultEntry(
            label = "Example",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(
                CredentialPayload(
                    username = "user@example.com",
                    password = "secret",
                    category = "Sources",
                )
            ),
            customFields = listOf(
                CustomField(id = "recovery", name = "Recovery", value = "line 1\nline 2"),
                CustomField(
                    id = entryReferenceFieldId,
                    name = "Owner",
                    value = target.id,
                    templateFieldId = entryReferenceFieldId,
                ),
                CustomField(
                    id = fieldReferenceFieldId,
                    name = "Server IP",
                    value = target.id,
                    templateFieldId = fieldReferenceFieldId,
                ),
            ),
        )
        val templates = listOf(
            CategoryTemplate(
                category = "Sources",
                fields = listOf(
                    FieldTemplate(
                        id = entryReferenceFieldId,
                        name = "Owner",
                        valueType = "entryReference",
                        targetCategory = "Targets",
                    ),
                    FieldTemplate(
                        id = fieldReferenceFieldId,
                        name = "Server IP",
                        valueType = "fieldReference",
                        targetCategory = "Targets",
                        targetFieldId = targetFieldId,
                    ),
                ),
            ),
            CategoryTemplate(
                category = "Targets",
                fields = listOf(FieldTemplate(id = targetFieldId, name = "IP")),
            ),
        )

        val text = entry.selectedFieldsText(
            fields = listOf(
                EntryTextExportField("label", "入口"),
                EntryTextExportField("credential.username", "用户名"),
                EntryTextExportField("custom.recovery", "Recovery"),
                EntryTextExportField("custom.$entryReferenceFieldId", "Owner"),
                EntryTextExportField("custom.$fieldReferenceFieldId", "Server IP"),
            ),
            categoryTemplates = templates,
            entries = listOf(entry, target),
        )

        assertEquals(
            listOf(
                "入口: Example",
                "用户名: user@example.com",
                "Recovery: line 1\\nline 2",
                "Owner: Target Server",
                "Server IP: Target Server: 10.0.0.8",
            ).joinToString("\n"),
            text,
        )
        assertFalse(text.contains("密码:"))
        assertFalse(text.contains(target.id))
        assertFalse(text.contains("{"))
        assertFalse(text.contains("scope"))
    }
}
