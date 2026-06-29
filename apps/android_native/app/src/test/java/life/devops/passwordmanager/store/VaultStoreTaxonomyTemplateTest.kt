package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CategoryTypePreset
import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.VaultEntryType
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class VaultStoreTaxonomyTemplateTest {
    @Test
    fun newCategoryStartsWithOnlyNameAndNotesTemplateFields() {
        val directory = createTempDirectory("PasswordManagerAndroidCategoryTemplateTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))

            assertTrue(store.addCategory("Private"))

            val template = assertNotNull(store.categoryTemplate("Private"))
            assertEquals(listOf("名称", "备注"), template.fields.map { it.name })
            assertTrue(template.fields.none { it.id.contains('-') })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun categoryPresetAddsExpectedFieldsWithoutChangingExistingEntries() {
        val directory = createTempDirectory("PasswordManagerAndroidCategoryPresetTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            val entry = store.upsert(
                EntryDraft(
                    label = "Existing",
                    type = VaultEntryType.CREDENTIAL,
                    category = "Infra",
                    tags = emptyList(),
                    customFields = listOf(CustomField(name = "Owner", value = "SRE")),
                )
            )

            assertTrue(store.applyCategoryPreset("Infra", CategoryTypePreset.SERVER))

            val template = assertNotNull(store.categoryTemplate("Infra"))
            assertEquals(listOf("名称", "备注", "IP地址", "端口", "关联账号"), template.fields.map { it.name })
            assertEquals(listOf("Owner" to "SRE"), store.listEntries().single { it.id == entry.id }.customFields.map { it.name to it.value })
            assertTrue(template.fields.none { it.id.contains('-') })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun categoryPresetAcceptsCustomFieldNames() {
        val directory = createTempDirectory("PasswordManagerAndroidCategoryCustomFieldTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))

            assertTrue(store.addCategory("Infra", CategoryTypePreset.SERVER, listOf("Owner", "备注", "")))

            val template = assertNotNull(store.categoryTemplate("Infra"))
            assertEquals(listOf("名称", "备注", "IP地址", "端口", "关联账号", "Owner"), template.fields.map { it.name })
            assertTrue(template.fields.none { it.id.contains('-') })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun categoryCustomFieldsDoNotRequireTypeShortcutState() {
        val directory = createTempDirectory("PasswordManagerAndroidCategoryCustomOnlyTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))

            assertTrue(store.addCategory("Ops", null, listOf("IP地址", "端口", "Owner", "ip地址", "")))

            val template = assertNotNull(store.categoryTemplate("Ops"))
            assertEquals(listOf("名称", "备注", "IP地址", "端口", "Owner"), template.fields.map { it.name })
            assertTrue(template.fields.none { it.id.contains('-') })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun templateDefaultsOnlyFillMissingCustomFieldNames() {
        val template = CategoryTemplate(
            category = "Service",
            fields = CategoryTemplate.fieldsForPreset(CategoryTypePreset.SERVICE),
        )
        val fields = listOf(CustomField(name = "备注", value = "keep"))
            .withTemplateDefaults(template)

        assertEquals(listOf("备注", "名称", "服务入口", "关联账号", "关联服务器"), fields.map { it.name })
        assertEquals("keep", fields.first().value)
    }
}
