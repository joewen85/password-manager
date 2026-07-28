package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.EntryReferenceStatus
import life.devops.passwordmanager.model.FieldTemplate
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultSnapshot
import life.devops.passwordmanager.model.resolveEntryReference
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class VaultStoreFieldReferenceLifecycleTest {
    @Test
    fun categoryRenameUpdatesReferenceTargetsAcrossAllTemplates() {
        withStore("PasswordManagerAndroidReferenceRenameTests") { store ->
            val ownerField = FieldTemplate(
                id = "template-owner",
                name = "Owner",
                valueType = "entryReference",
                targetCategory = " accounts ",
            )
            val serviceOwnerField = FieldTemplate(
                id = "template-service-owner",
                name = "Service Owner",
                valueType = "entryReference",
                targetCategory = "ACCOUNTS",
            )
            val futureField = FieldTemplate(
                id = "template-future",
                name = "Future",
                valueType = "futureReference",
                targetCategory = " accounts ",
            )
            val otherReferenceField = FieldTemplate(
                id = "template-other",
                name = "Other",
                valueType = "entryReference",
                targetCategory = "Other",
            )
            assertTrue(store.addCategory("Accounts"))
            assertTrue(store.addCategory("Servers", listOf(ownerField, futureField, otherReferenceField)))
            assertTrue(store.addCategory("Services", listOf(serviceOwnerField)))
            val target = store.upsert(entryDraft(label = "Account", category = "Accounts"))
            val source = store.upsert(
                entryDraft(
                    label = "Server",
                    category = "Servers",
                    customFields = listOf(referenceValue(ownerField, target)),
                )
            )

            assertTrue(store.renameCategory(" accounts ", " Identity "))

            val snapshot = snapshot(store)
            val updatedServers = assertNotNull(
                snapshot.categoryTemplates.firstOrNull { it.category == "Servers" }
            )
            val updatedServices = assertNotNull(
                snapshot.categoryTemplates.firstOrNull { it.category == "Services" }
            )
            assertEquals(ownerField.copy(targetCategory = "Identity"), updatedServers.fields[0])
            assertEquals(futureField, updatedServers.fields[1])
            assertEquals(otherReferenceField, updatedServers.fields[2])
            assertEquals(
                serviceOwnerField.copy(targetCategory = "Identity"),
                updatedServices.fields.single(),
            )
            assertTrue(snapshot.categoryTemplates.any { it.category == "Identity" })
            assertTrue(snapshot.categoryTemplates.none { it.category == "Accounts" })

            val savedSource = snapshot.entry(source.id)
            val savedTarget = snapshot.entry(target.id)
            val savedReference = savedSource.customFields.single()
            assertEquals(target.id, savedReference.value)
            assertEquals("Identity", savedTarget.payload.category)
            assertEquals(
                EntryReferenceStatus.RESOLVED,
                resolveEntryReference(savedReference, updatedServers, snapshot.entries)?.status,
            )
        }
    }

    @Test
    fun categoryDeleteKeepsReferenceTargetAndSourceValue() {
        withStore("PasswordManagerAndroidReferenceCategoryDeleteTests") { store ->
            val ownerField = referenceTemplateField(targetCategory = " accounts ")
            assertTrue(store.addCategory("Accounts"))
            assertTrue(store.addCategory("Servers", listOf(ownerField)))
            val target = store.upsert(entryDraft(label = "Account", category = "Accounts"))
            val source = store.upsert(
                entryDraft(
                    label = "Server",
                    category = "Servers",
                    customFields = listOf(referenceValue(ownerField, target)),
                )
            )

            assertTrue(store.deleteCategory(" ACCOUNTS "))

            val snapshot = snapshot(store)
            val sourceTemplate = assertNotNull(
                snapshot.categoryTemplates.firstOrNull { it.category == "Servers" }
            )
            val savedReference = snapshot.entry(source.id).customFields.single()
            assertEquals(" accounts ", sourceTemplate.fields.single().targetCategory)
            assertEquals(target.id, savedReference.value)
            assertEquals("", snapshot.entry(target.id).payload.category)
            assertEquals(
                EntryReferenceStatus.CATEGORY_MISMATCH,
                resolveEntryReference(savedReference, sourceTemplate, snapshot.entries)?.status,
            )
        }
    }

    @Test
    fun targetDeleteRestoreAndMoveKeepReferenceValueAndUpdateResolution() {
        withStore("PasswordManagerAndroidReferenceEntryLifecycleTests") { store ->
            val ownerField = referenceTemplateField(targetCategory = "Accounts")
            assertTrue(store.addCategory("Accounts"))
            assertTrue(store.addCategory("Servers", listOf(ownerField)))
            assertTrue(store.addCategory("Archive"))
            val target = store.upsert(entryDraft(label = "Account", category = "Accounts"))
            val source = store.upsert(
                entryDraft(
                    label = "Server",
                    category = "Servers",
                    customFields = listOf(referenceValue(ownerField, target)),
                )
            )

            store.delete(target.id)
            assertReferenceState(
                snapshot = snapshot(store),
                sourceId = source.id,
                targetId = target.id,
                expectedStatus = EntryReferenceStatus.DELETED,
            )

            val restored = store.upsert(
                draft = entryDraft(label = "Account restored", category = "Accounts"),
                editingId = target.id,
            )
            assertEquals(target.id, restored.id)
            assertReferenceState(
                snapshot = snapshot(store),
                sourceId = source.id,
                targetId = target.id,
                expectedStatus = EntryReferenceStatus.RESOLVED,
            )

            val moved = store.upsert(
                draft = entryDraft(label = restored.label, category = "Archive"),
                editingId = target.id,
            )
            assertEquals(target.id, moved.id)
            assertReferenceState(
                snapshot = snapshot(store),
                sourceId = source.id,
                targetId = target.id,
                expectedStatus = EntryReferenceStatus.CATEGORY_MISMATCH,
            )
        }
    }

    private fun assertReferenceState(
        snapshot: VaultSnapshot,
        sourceId: String,
        targetId: String,
        expectedStatus: EntryReferenceStatus,
    ) {
        val source = snapshot.entry(sourceId)
        val sourceTemplate = assertNotNull(
            snapshot.categoryTemplates.firstOrNull { it.category == source.payload.category }
        )
        val reference = source.customFields.single()
        assertEquals(targetId, reference.value)
        assertEquals(
            expectedStatus,
            resolveEntryReference(reference, sourceTemplate, snapshot.entries)?.status,
        )
    }

    private fun referenceTemplateField(targetCategory: String): FieldTemplate =
        FieldTemplate(
            id = "template-owner",
            name = "Owner",
            valueType = "entryReference",
            targetCategory = targetCategory,
        )

    private fun referenceValue(templateField: FieldTemplate, target: VaultEntry): CustomField =
        CustomField(
            id = "owner-${target.id}",
            templateFieldId = templateField.id,
            name = templateField.name,
            value = target.id,
        )

    private fun entryDraft(
        label: String,
        category: String,
        customFields: List<CustomField> = emptyList(),
    ): EntryDraft =
        EntryDraft(
            label = label,
            type = VaultEntryType.CREDENTIAL,
            category = category,
            tags = emptyList(),
            customFields = customFields,
        )

    private fun snapshot(store: VaultStore): VaultSnapshot =
        VaultJson.decodeSnapshot(assertNotNull(store.exportSnapshotJson()))

    private fun VaultSnapshot.entry(id: String): VaultEntry =
        assertNotNull(entries.firstOrNull { entry -> entry.id == id })

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
