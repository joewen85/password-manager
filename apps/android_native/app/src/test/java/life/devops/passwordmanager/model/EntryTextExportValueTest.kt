package life.devops.passwordmanager.model

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import life.devops.passwordmanager.store.FileVaultRepository
import life.devops.passwordmanager.store.VaultJson
import life.devops.passwordmanager.store.VaultStore

class EntryTextExportValueTest {
    @Test
    fun templateEntriesExposeStoredCustomValuesWithoutLegacyPayloadFields() {
        val username = CustomField(id = "username-field", name = "用户名", value = "template-user")
        val password = CustomField(id = "password-field", name = "密码", value = "template-password")
        val entry = VaultEntry(
            label = "Template Credential",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(CredentialPayload(category = "Accounts")),
            customFields = listOf(username, password),
        )

        assertTrue(!entry.hasLegacyExportValues)
        assertEquals(
            "用户名: template-user\n密码: template-password",
            entry.selectedFieldsText(
                fields = listOf(
                    EntryTextExportField("custom." + username.id, username.name),
                    EntryTextExportField("custom." + password.id, password.name),
                ),
                categoryTemplates = emptyList(),
                entries = listOf(entry),
            ),
        )
    }

    @Test
    fun credentialValuesAndServerAccountReferencesAreExported() {
        val account = VaultEntry(
            id = "account-entry",
            label = "Primary Account",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(CredentialPayload()),
        )
        val credential = VaultEntry(
            label = "Credential",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(
                CredentialPayload(username = "saved-user", password = "saved-password")
            ),
        )
        val server = VaultEntry(
            label = "Server",
            type = VaultEntryType.SERVER,
            payload = VaultPayload.Server(
                ServerPayload(
                    username = "root",
                    password = "server-password",
                    accountId = account.id,
                )
            ),
        )

        assertEquals(
            "用户名: saved-user\n密码: saved-password",
            credential.selectedFieldsText(
                fields = listOf(
                    EntryTextExportField("credential.username", "用户名"),
                    EntryTextExportField("credential.password", "密码"),
                ),
                categoryTemplates = emptyList(),
                entries = listOf(credential),
            ),
        )
        assertEquals(
            "用户名: root\n密码: server-password\n关联账号: Primary Account",
            server.selectedFieldsText(
                fields = listOf(
                    EntryTextExportField("server.username", "用户名"),
                    EntryTextExportField("server.password", "密码"),
                    EntryTextExportField("server.accountId", "关联账号"),
                ),
                categoryTemplates = emptyList(),
                entries = listOf(server, account),
            ),
        )
    }

    @Test
    fun storeJsonExportReloadsCurrentValuesAndKeepsSelectedServerAccount() {
        val directory = createTempDirectory("PasswordManagerAndroidCurrentEntryExportTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            val staleEntry = store.upsert(
                EntryDraft(
                    label = "Server",
                    type = VaultEntryType.SERVER,
                    category = "Servers",
                    tags = emptyList(),
                    server = ServerPayload(
                        username = "old-user",
                        password = "old-password",
                        accountId = "account-entry",
                    ),
                )
            )
            store.upsert(
                EntryDraft(
                    label = "Server",
                    type = VaultEntryType.SERVER,
                    category = "Servers",
                    tags = emptyList(),
                    server = ServerPayload(
                        username = "current-user",
                        password = "current-password",
                        accountId = "account-entry",
                    ),
                ),
                editingId = staleEntry.id,
            )

            val export = VaultJson.decodeScopedExport(assertNotNull(store.exportEntryJson(
                staleEntry,
                setOf("server.username", "server.password", "server.accountId"),
            )))
            val server = assertNotNull((export.item?.payload as? VaultPayload.Server)?.value)
            assertEquals("current-user", server.username)
            assertEquals("current-password", server.password)
            assertEquals("account-entry", server.accountId)
        } finally {
            File(directory.path).deleteRecursively()
        }
    }
}
