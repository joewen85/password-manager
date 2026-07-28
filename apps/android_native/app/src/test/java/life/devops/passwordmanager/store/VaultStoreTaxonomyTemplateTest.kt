package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CategoryTypePreset
import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.FieldTemplate
import life.devops.passwordmanager.model.VaultEntryType
import java.io.File
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
            fields = CategoryTemplate.fieldsForPreset(CategoryTypePreset.SERVICE) + FieldTemplate(
                id = "template-owner",
                name = "Owner",
                valueType = "entryReference",
                targetCategory = "Accounts",
            ),
        )
        val fields = listOf(CustomField(name = "备注", value = "keep"))
            .withTemplateDefaults(template)

        assertEquals(listOf("备注", "名称", "服务入口", "关联账号", "关联服务器"), fields.map { it.name })
        assertEquals("keep", fields.first().value)
        assertEquals(
            template.fields
                .filter { it.valueType == "text" && it.name != "备注" }
                .map { it.id }
                .toSet(),
            fields.drop(1).map { it.templateFieldId }.toSet(),
        )
    }

    @Test
    fun scopedExportsIncludeOnlySourceCategoryTemplateAndEntries() {
        val directory = createTempDirectory("PasswordManagerAndroidScopedTemplateTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            assertTrue(
                store.addCategory(
                    "Accounts",
                    listOf(FieldTemplate(id = "template-login", name = "Login")),
                )
            )
            val ownerTemplate = FieldTemplate(
                id = "Template-Owner-ID",
                name = "Owner",
                valueType = "entryReference",
                targetCategory = "Accounts",
            )
            assertTrue(store.addCategory("Servers", listOf(ownerTemplate)))
            val target = store.upsert(
                EntryDraft(
                    label = "Target Account",
                    type = VaultEntryType.CREDENTIAL,
                    category = "Accounts",
                    tags = emptyList(),
                )
            )
            val source = store.upsert(
                EntryDraft(
                    label = "Source Server",
                    type = VaultEntryType.CREDENTIAL,
                    category = "Servers",
                    tags = emptyList(),
                    customFields = listOf(
                        CustomField(
                            templateFieldId = ownerTemplate.id,
                            name = ownerTemplate.name,
                            value = target.id,
                        )
                    ),
                )
            )

            val itemExportJson = assertNotNull(store.exportEntryJson(source))
            val itemExport = VaultJson.decodeScopedExport(itemExportJson)
            val categoryExport = VaultJson.decodeScopedExport(
                assertNotNull(store.exportCategoryJson("Servers"))
            )
            store.exportEntry(source)
            store.exportCategory("Servers")
            val fileExports = File(directory, "exports")
                .listFiles()
                .orEmpty()
                .map { VaultJson.decodeScopedExport(it.readText()) }

            assertEquals(2, itemExport.version)
            assertEquals(listOf("Servers"), itemExport.categoryTemplates.map { it.category })
            assertEquals(source.id, itemExport.item?.id)
            assertTrue(itemExport.item?.customFields?.single()?.value == target.id)
            assertEquals(2, categoryExport.version)
            assertEquals(listOf("Servers"), categoryExport.categoryTemplates.map { it.category })
            assertEquals(listOf(source.id), categoryExport.items?.map { it.id })
            assertTrue(categoryExport.items.orEmpty().none { it.id == target.id })
            assertEquals(2, fileExports.size)
            assertTrue(fileExports.all { it.version == 2 })
            assertTrue(fileExports.all { export ->
                export.categoryTemplates.map { it.category } == listOf("Servers")
            })
            assertTrue(fileExports.flatMap { it.items.orEmpty() }.none { it.id == target.id })
            assertTrue(fileExports.mapNotNull { it.item }.none { it.id == target.id })

            val importDirectory = createTempDirectory("PasswordManagerAndroidScopedTemplateImportTests").toFile()
            try {
                val importStore = VaultStore(repository = FileVaultRepository(importDirectory))
                assertTrue(importStore.setupMasterPassword("test-password", "test-password"))
                assertTrue(
                    importStore.importScopedExportJson(
                        itemExportJson,
                        life.devops.passwordmanager.model.ImportConflictStrategy.KEEP_COPY,
                    )
                )
                assertEquals(
                    listOf(ownerTemplate),
                    importStore.categoryTemplate("Servers")?.fields,
                )
                assertTrue(importStore.listEntries().none { it.id == target.id })
            } finally {
                importDirectory.deleteRecursively()
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun editingPreservesNonTextTemplateFieldsAndUpdatesTextFields() {
        val directory = createTempDirectory("PasswordManagerAndroidProtectedFieldTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            val template = CategoryTemplate(
                category = "Servers",
                fields = listOf(
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
            assertTrue(store.addCategory(template.category, template.fields))
            val original = store.upsert(
                EntryDraft(
                    label = "Server",
                    type = VaultEntryType.CREDENTIAL,
                    category = template.category,
                    tags = emptyList(),
                    customFields = listOf(
                        CustomField(
                            id = "owner-instance",
                            templateFieldId = "template-owner",
                            name = "Owner",
                            value = "account-id",
                        ),
                        CustomField(
                            id = "future-instance",
                            name = "Future",
                            value = "future-value",
                        ),
                        CustomField(
                            id = "notes-instance",
                            templateFieldId = "template-notes",
                            name = "Notes",
                            value = "old text",
                        ),
                        CustomField(id = "ordinary-instance", name = "Ordinary", value = "old custom"),
                    ),
                )
            )
            val originalOwner = original.customFields.single { it.id == "owner-instance" }
            val originalFuture = original.customFields.single { it.id == "future-instance" }

            val saved = store.upsert(
                EntryDraft(
                    label = original.label,
                    type = original.type,
                    category = original.payload.category,
                    tags = original.payload.tags,
                    customFields = listOf(
                        CustomField(
                            id = "notes-instance",
                            templateFieldId = "template-notes",
                            name = "Notes",
                            value = "new text",
                        ),
                        CustomField(id = "ordinary-instance", name = "Ordinary", value = "new custom"),
                    ),
                ),
                editingId = original.id,
            )

            assertEquals(originalOwner, saved.customFields.single { it.id == "owner-instance" })
            assertEquals(originalFuture, saved.customFields.single { it.id == "future-instance" })
            assertEquals("new text", saved.customFields.single { it.id == "notes-instance" }.value)
            assertEquals("new custom", saved.customFields.single { it.id == "ordinary-instance" }.value)
        } finally {
            directory.deleteRecursively()
        }
    }
}
