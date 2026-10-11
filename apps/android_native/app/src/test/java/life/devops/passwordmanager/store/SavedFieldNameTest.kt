package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.VaultEntryType
import kotlin.io.path.createTempDirectory
import kotlin.test.*

class SavedFieldNameTest {
    @Test
    fun savedNamesAreFixedButValuesAndReplacementFieldsCanChange() {
        val directory = createTempDirectory("saved-field-names").toFile()
        try {
            val store = VaultStore(FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            val first = store.upsert(EntryDraft(label = "Entry", type = VaultEntryType.CREDENTIAL, category = "", tags = emptyList(),
                customFields = listOf(CustomField(id = "saved", name = "Owner", value = "alice"))))
            val edited = store.upsert(EntryDraft(label = "Entry", type = VaultEntryType.CREDENTIAL, category = "", tags = emptyList(),
                customFields = listOf(first.customFields.single().copy(name = "Renamed", value = "bob"),
                    CustomField(id = "new", name = "Region", value = "east"))), first.id)
            assertEquals("Owner", edited.customFields.first { it.id == "saved" }.name)
            assertEquals("bob", edited.customFields.first { it.id == "saved" }.value)
            assertEquals("Region", edited.customFields.first { it.id == "new" }.name)
            store.lock()
            assertTrue(store.unlock("test-password"))
            assertEquals(edited.customFields, store.listEntries().single().customFields)
            val replaced = store.upsert(EntryDraft(label = "Entry", type = VaultEntryType.CREDENTIAL, category = "", tags = emptyList(),
                customFields = listOf(CustomField(id = "replacement", name = "Primary Owner", value = "carol"))), first.id)
            assertEquals(listOf("replacement"), replaced.customFields.map { it.id })
            assertEquals("Primary Owner", replaced.customFields.single().name)
            val locked = store.upsert(EntryDraft(label = "Entry", type = VaultEntryType.CREDENTIAL, category = "", tags = emptyList(),
                customFields = listOf(replaced.customFields.single().copy(name = "Again"))), first.id)
            assertEquals("Primary Owner", locked.customFields.single().name)
        } finally { directory.deleteRecursively() }
    }
}
