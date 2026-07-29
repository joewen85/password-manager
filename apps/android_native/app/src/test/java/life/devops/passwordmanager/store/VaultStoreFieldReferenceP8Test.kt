package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CategoryTypePreset
import life.devops.passwordmanager.model.CredentialPayload
import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.FieldReferenceStatus
import life.devops.passwordmanager.model.FieldTemplate
import life.devops.passwordmanager.model.ImportConflictStrategy
import life.devops.passwordmanager.model.ScopedExportScope
import life.devops.passwordmanager.model.ScopedVaultExport
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import life.devops.passwordmanager.model.VaultSnapshot
import life.devops.passwordmanager.model.resolveFieldReference
import life.devops.passwordmanager.sync.VaultSyncPayload
import java.time.Instant
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class VaultStoreFieldReferenceP8Test {
    @Test
    fun scopedCopyImportRemapsSourceEntryIdButPreservesTargetFieldId() {
        withStore("PasswordManagerAndroidFieldReferenceCopyTests") { store ->
            val contract = contract(sourceCategory = "Accounts", targetCategory = "Accounts")

            assertTrue(
                store.importScopedExportJson(
                    VaultJson.encodeScopedExport(contract.export),
                    ImportConflictStrategy.KEEP_COPY,
                ),
            )

            val importedTarget = store.listEntries().single { it.label == contract.target.label }
            val importedSource = store.listEntries().single { it.label == contract.source.label }
            val importedReference = importedSource.customFields.single()
            assertTrue(importedTarget.id != contract.target.id)
            assertEquals(importedTarget.id, importedReference.value)
            assertEquals(contract.sourceField.targetFieldId, store.categoryTemplate("Accounts")
                ?.fields?.single { it.id == contract.sourceField.id }?.targetFieldId)
        }
    }

    @Test
    fun searchIndexesOnlyResolvedSafeProjectionAndNeverTargetValueOrIds() {
        withStore("PasswordManagerAndroidFieldReferenceSearchTests") { store ->
            val contract = contract()
            assertTrue(
                store.importScopedExportJson(
                    VaultJson.encodeScopedExport(contract.export),
                    ImportConflictStrategy.KEEP_COPY,
                ),
            )
            val importedTarget = store.listEntries().single { it.label == contract.target.label }
            val importedSource = store.listEntries().single { it.label == contract.source.label }

            listOf(contract.target.label, "Accounts", contract.targetField.name).forEach { query ->
                assertTrue(store.listEntries(query = query).any { it.id == importedSource.id })
            }
            listOf(
                contract.targetValue.value,
                contract.target.id,
                importedTarget.id,
                contract.targetField.id,
                "target-password-secret",
            ).forEach { forbidden ->
                assertTrue(store.listEntries(query = forbidden).none { it.id == importedSource.id })
            }
        }
    }

    @Test
    fun categoryRenamePropagatesFieldReferenceTargetOnly() {
        withStore("PasswordManagerAndroidFieldReferenceRenameTests") { store ->
            val targetField = targetField()
            val fieldReference = sourceField(targetCategory = " accounts ", targetFieldId = targetField.id)
            val unknown = fieldReference.copy(
                id = "future-reference",
                valueType = "futureFieldReference",
            )
            assertTrue(store.addCategory("Accounts", listOf(targetField)))
            assertTrue(store.addCategory("Servers", listOf(fieldReference, unknown)))

            assertTrue(store.renameCategory("ACCOUNTS", "Identity"))

            val fields = assertNotNull(store.categoryTemplate("Servers")).fields
            assertEquals("Identity", fields.single { it.id == fieldReference.id }.targetCategory)
            assertEquals(" accounts ", fields.single { it.id == unknown.id }.targetCategory)
        }
    }

    @Test
    fun storeTemplateSaveAndPresetProtectReferencedTargetTextField() {
        withStore("PasswordManagerAndroidFieldReferenceTemplateSafetyTests") { store ->
            val targetField = targetField()
            val fieldReference = sourceField(targetFieldId = targetField.id)
            assertTrue(store.addCategory("Accounts", listOf(targetField)))
            assertTrue(store.addCategory("Servers", listOf(fieldReference)))

            assertTrue(
                store.updateCategoryTemplate(
                    "Accounts",
                    listOf(targetField.copy(name = "Login name")),
                ),
            )
            assertEquals(
                "Login name",
                store.categoryTemplate("Accounts")?.fields
                    ?.single { field -> field.id == targetField.id }
                    ?.name,
            )

            assertTrue(
                store.updateCategoryTemplate(
                    "Accounts",
                    listOf(targetField.copy(name = "Unsafe", valueType = "entryReference")),
                ),
            )
            val afterTypeChange = assertNotNull(store.categoryTemplate("Accounts"))
                .fields.single { it.id == targetField.id }
            assertEquals("Login name", afterTypeChange.name)
            assertEquals("text", afterTypeChange.valueType)

            assertTrue(store.updateCategoryTemplate("Accounts", emptyList()))
            assertTrue(store.categoryTemplate("Accounts")?.fields?.any { it.id == targetField.id } == true)
            assertTrue(store.applyCategoryPreset("Accounts", CategoryTypePreset.ACCOUNT))
            assertTrue(store.categoryTemplate("Accounts")?.fields?.any { it.id == targetField.id } == true)

            assertTrue(store.updateCategoryTemplate("Servers", emptyList()))
            assertEquals(
                fieldReference,
                store.categoryTemplate("Servers")?.fields
                    ?.single { field -> field.id == fieldReference.id },
            )
        }
    }

    @Test
    fun syncRoundTripPreservesResolvableFieldReference() {
        val contract = contract()
        val snapshot = VaultSnapshot(
            entries = listOf(contract.target, contract.source),
            categories = listOf("Accounts", "Servers"),
            categoryTemplates = contract.export.categoryTemplates,
        )

        val synced = VaultSyncPayload.fromJson(
            VaultSyncPayload(
                exportedAt = Instant.parse("2026-07-29T00:00:00Z"),
                deviceId = "android-p8-test",
                revision = 8,
                snapshot = snapshot,
            ).toJson().toString(),
        ).snapshot
        val source = synced.entries.single { it.id == contract.source.id }
        val sourceTemplate = synced.categoryTemplates.single {
            it.category == contract.source.payload.category
        }

        assertEquals(
            FieldReferenceStatus.RESOLVED,
            resolveFieldReference(
                field = source.customFields.single(),
                sourceTemplate = sourceTemplate,
                categoryTemplates = synced.categoryTemplates,
                entries = synced.entries,
            )?.status,
        )
    }

    private fun contract(
        sourceCategory: String = "Servers",
        targetCategory: String = "Accounts",
    ): ContractFixture {
        val targetField = targetField()
        val sourceField = sourceField(
            targetCategory = targetCategory,
            targetFieldId = targetField.id,
        )
        val targetValue = CustomField(
            id = "target-value",
            templateFieldId = targetField.id,
            name = targetField.name,
            value = "private-target-value",
        )
        val target = VaultEntry(
            id = "target-entry",
            label = "Payroll Account",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(
                CredentialPayload(password = "target-password-secret", category = targetCategory),
            ),
            customFields = listOf(targetValue),
        )
        val source = VaultEntry(
            id = "source-entry",
            label = "Payroll Server",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(CredentialPayload(category = sourceCategory)),
            customFields = listOf(
                CustomField(
                    id = "source-value",
                    templateFieldId = sourceField.id,
                    name = sourceField.name,
                    value = target.id,
                ),
            ),
        )
        val templates = if (sourceCategory.equals(targetCategory, ignoreCase = true)) {
            listOf(CategoryTemplate(sourceCategory, listOf(targetField, sourceField)))
        } else {
            listOf(
                CategoryTemplate(targetCategory, listOf(targetField)),
                CategoryTemplate(sourceCategory, listOf(sourceField)),
            )
        }
        return ContractFixture(
            sourceField = sourceField,
            targetField = targetField,
            targetValue = targetValue,
            target = target,
            source = source,
            export = ScopedVaultExport(
                scope = ScopedExportScope.CATEGORY,
                category = sourceCategory,
                items = listOf(target, source),
                categoryTemplates = templates,
            ),
        )
    }

    private fun targetField(): FieldTemplate =
        FieldTemplate(id = "target-login", name = "Login alias")

    private fun sourceField(
        targetCategory: String = "Accounts",
        targetFieldId: String,
    ): FieldTemplate = FieldTemplate(
        id = "source-account-login",
        name = "Linked login",
        valueType = "fieldReference",
        targetCategory = targetCategory,
        targetFieldId = targetFieldId,
    )

    private data class ContractFixture(
        val sourceField: FieldTemplate,
        val targetField: FieldTemplate,
        val targetValue: CustomField,
        val target: VaultEntry,
        val source: VaultEntry,
        val export: ScopedVaultExport,
    )

    private inline fun withStore(name: String, block: (VaultStore) -> Unit) {
        val directory = createTempDirectory(name).toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            block(store)
        } finally {
            directory.deleteRecursively()
        }
    }
}
