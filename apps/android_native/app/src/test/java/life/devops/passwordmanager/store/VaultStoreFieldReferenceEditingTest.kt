package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CredentialPayload
import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.EntryReferenceCandidate
import life.devops.passwordmanager.model.EntryReferenceStatus
import life.devops.passwordmanager.model.EntryReferenceTarget
import life.devops.passwordmanager.model.FieldTemplate
import life.devops.passwordmanager.model.ImportConflictStrategy
import life.devops.passwordmanager.model.ScopedExportScope
import life.devops.passwordmanager.model.ScopedVaultExport
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VaultStoreFieldReferenceEditingTest {
    @Test
    fun modernUpsertUsesDestinationTemplateAndProtectedIdsWithoutCrossCategoryValueBleed() {
        withStore("PasswordManagerAndroidModernFieldSaveTests") { store ->
            val sourceTemplate = categoryTemplate("A")
            val destinationTemplate = categoryTemplate("B")
            val target = store.upsert(entryDraft(label = "Target", category = "Accounts"))
            val sourceText = CustomField(
                id = "a-text-instance",
                templateFieldId = SHARED_TEXT_TEMPLATE_ID,
                name = "Notes",
                value = "A text",
            )
            val sourceReference = CustomField(
                id = "a-reference-instance",
                templateFieldId = SHARED_REFERENCE_TEMPLATE_ID,
                name = "Owner",
                value = target.id,
            )
            val unknown = CustomField(
                id = "a-unknown-instance",
                templateFieldId = "future-template-id",
                name = "Future",
                value = "opaque-future-value",
            )
            val orphan = CustomField(
                id = "a-orphan-instance",
                templateFieldId = "missing-template-id",
                name = "Orphan",
                value = "opaque-orphan-value",
            )
            importEntry(
                store = store,
                entry = vaultEntry(
                    id = "source-a",
                    label = "Source A",
                    category = "A",
                    customFields = listOf(sourceText, sourceReference, unknown, orphan),
                ),
                template = sourceTemplate,
            )
            assertTrue(store.addCategory("B", destinationTemplate.fields))
            val imported = assertNotNull(store.listEntries().firstOrNull { it.label == "Source A" })
            val destinationText = CustomField(
                id = "b-text-instance",
                templateFieldId = SHARED_TEXT_TEMPLATE_ID,
                name = "Notes",
                value = "B text",
            )
            val destinationReference = CustomField(
                id = "b-reference-instance",
                templateFieldId = SHARED_REFERENCE_TEMPLATE_ID,
                name = "Owner",
                value = target.id,
            )

            val saved = store.upsert(
                draft = entryDraft(
                    label = imported.label,
                    category = "B",
                    customFields = imported.customFields + destinationText + destinationReference,
                ),
                editingId = imported.id,
                protectedFieldIds = imported.customFields.mapTo(mutableSetOf()) { it.id },
            )

            assertEquals("B", saved.payload.category)
            assertEquals("B text", saved.customFields.single { it.id == destinationText.id }.value)
            assertEquals(target.id, saved.customFields.single { it.id == destinationReference.id }.value)
            assertFalse(saved.customFields.any { it.id == sourceText.id })
            assertFalse(saved.customFields.any { it.id == sourceReference.id })
            assertEquals(unknown, saved.customFields.single { it.id == unknown.id })
            assertEquals(orphan, saved.customFields.single { it.id == orphan.id })

            val protectedSourceDraft = CustomField(
                id = "protected-source-create",
                templateFieldId = SHARED_TEXT_TEMPLATE_ID,
                name = "Notes",
                value = "must not persist",
            )
            val activeDestinationDraft = destinationText.copy(id = "active-destination-create")
            val created = store.upsert(
                draft = entryDraft(
                    label = "Created in B",
                    category = "B",
                    customFields = listOf(protectedSourceDraft, activeDestinationDraft),
                ),
                protectedFieldIds = setOf(protectedSourceDraft.id),
            )
            assertEquals(listOf(activeDestinationDraft), created.customFields)
        }
    }

    @Test
    fun candidatesAndResolutionExposeOnlyLiveSafeReferenceProjections() {
        withStore("PasswordManagerAndroidReferenceProjectionTests") { store ->
            val referenceTemplate = referenceTemplateField()
            assertTrue(store.addCategory("Servers", listOf(referenceTemplate)))
            val alpha = store.upsert(
                entryDraft(
                    label = "Alpha Account",
                    category = "Accounts",
                    customFields = listOf(CustomField(name = "Secret", value = "alpha-custom-secret")),
                    credential = CredentialPayload(
                        password = "alpha-password-secret",
                        token = "alpha-token-secret",
                    ),
                )
            )
            val beta = store.upsert(entryDraft(label = "Beta Account", category = " accounts "))
            store.upsert(entryDraft(label = "Wrong Category", category = "Archive"))
            val deleted = store.upsert(entryDraft(label = "Deleted Account", category = "Accounts"))
            store.delete(deleted.id)

            assertEquals(
                listOf(alpha.id, beta.id),
                store.entryReferenceCandidates(" ACCOUNTS ", "")
                    .map { candidate -> candidate.id },
            )
            assertEquals(
                EntryReferenceCandidate(alpha.id, alpha.label, "Accounts"),
                store.entryReferenceCandidates("Accounts", "alpha").single(),
            )
            assertEquals(
                listOf(alpha.id, beta.id),
                store.entryReferenceCandidates("", "accounts").map { candidate -> candidate.id },
            )
            assertTrue(store.entryReferenceCandidates("", alpha.id).isEmpty())
            assertTrue(store.entryReferenceCandidates("", "alpha-custom-secret").isEmpty())
            assertTrue(store.entryReferenceCandidates("", "alpha-password-secret").isEmpty())
            assertTrue(store.entryReferenceCandidates("", "alpha-token-secret").isEmpty())
            assertEquals(alpha.id, store.liveEntry(alpha.id)?.id)
            assertNull(store.liveEntry(deleted.id))

            assertEquals(
                EntryReferenceStatus.EMPTY,
                store.resolveEntryReference(referenceValue(referenceTemplate, ""), "Servers")?.status,
            )
            assertEquals(
                EntryReferenceStatus.MISSING,
                store.resolveEntryReference(referenceValue(referenceTemplate, "missing-target"), "Servers")?.status,
            )
            val resolved = assertNotNull(
                store.resolveEntryReference(referenceValue(referenceTemplate, alpha.id), "Servers")
            )
            assertEquals(EntryReferenceStatus.RESOLVED, resolved.status)
            assertEquals(
                EntryReferenceTarget(id = alpha.id, label = alpha.label, category = "Accounts"),
                resolved.target,
            )
            assertEquals(
                EntryReferenceStatus.DELETED,
                store.resolveEntryReference(referenceValue(referenceTemplate, deleted.id), "Servers")?.status,
            )

            store.upsert(
                draft = entryDraft(label = alpha.label, category = "Archive"),
                editingId = alpha.id,
            )
            assertEquals(
                EntryReferenceStatus.CATEGORY_MISMATCH,
                store.resolveEntryReference(referenceValue(referenceTemplate, alpha.id), "Servers")?.status,
            )
            assertNull(
                store.resolveEntryReference(
                    CustomField(
                        templateFieldId = "missing-template",
                        name = "Unknown",
                        value = "must-not-be-projected",
                    ),
                    "Servers",
                )
            )
        }
    }

    @Test
    fun upsertPreservesOpaqueReferenceIdsExactlyWhileStillNormalizingTextValues() {
        withStore("PasswordManagerAndroidOpaqueReferenceValueTests") { store ->
            val referenceTemplate = referenceTemplateField()
            val textTemplate = FieldTemplate(id = "text-template", name = "Notes")
            assertTrue(store.addCategory("Servers", listOf(referenceTemplate, textTemplate)))
            val target = store.upsert(entryDraft(label = "Target", category = "Accounts"))
            val opaqueReference = referenceValue(referenceTemplate, "  ${target.id}  ").copy(
                id = "opaque-reference-instance",
            )
            val text = CustomField(
                id = "text-instance",
                templateFieldId = textTemplate.id,
                name = textTemplate.name,
                value = "  normalized text  ",
            )

            val saved = store.upsert(
                entryDraft(
                    label = "Source",
                    category = "Servers",
                    customFields = listOf(opaqueReference, text),
                )
            )

            assertEquals("  ${target.id}  ", saved.customFields.single { it.id == opaqueReference.id }.value)
            assertEquals("normalized text", saved.customFields.single { it.id == text.id }.value)
            assertEquals(
                EntryReferenceStatus.MISSING,
                store.resolveEntryReference(
                    saved.customFields.single { it.id == opaqueReference.id },
                    "Servers",
                )?.status,
            )

            val exactReference = opaqueReference.copy(value = target.id)
            val updated = store.upsert(
                draft = entryDraft(
                    label = saved.label,
                    category = "Servers",
                    customFields = listOf(exactReference, text.copy(value = "normalized text")),
                ),
                editingId = saved.id,
            )
            assertEquals(target.id, updated.customFields.single { it.id == opaqueReference.id }.value)
            assertEquals(
                EntryReferenceStatus.RESOLVED,
                store.resolveEntryReference(
                    updated.customFields.single { it.id == opaqueReference.id },
                    "Servers",
                )?.status,
            )
        }
    }

    @Test
    fun directClearOnlyChangesRecognizedReferenceAndKeepsOpaqueFieldsLossless() {
        withStore("PasswordManagerAndroidReferenceClearTests") { store ->
            val referenceTemplate = referenceTemplateField()
            val futureTemplate = FieldTemplate(
                id = "future-template",
                name = "Future",
                valueType = "futureReferenceV3",
            )
            val sourceTemplate = CategoryTemplate(
                category = "Servers",
                fields = listOf(referenceTemplate, futureTemplate),
            )
            val target = store.upsert(entryDraft(label = "Target Account", category = "Accounts"))
            val reference = CustomField(
                id = "reference-instance",
                templateFieldId = referenceTemplate.id,
                name = referenceTemplate.name,
                value = target.id,
            )
            val unknown = CustomField(
                id = "unknown-instance",
                templateFieldId = futureTemplate.id,
                name = futureTemplate.name,
                value = "opaque-unknown-value",
            )
            val orphan = CustomField(
                id = "orphan-instance",
                templateFieldId = "removed-template",
                name = "Removed",
                value = "opaque-orphan-value",
            )
            importEntry(
                store = store,
                entry = vaultEntry(
                    id = "source-reference-clear",
                    label = "Source Server",
                    category = sourceTemplate.category,
                    customFields = listOf(reference, unknown, orphan),
                ),
                template = sourceTemplate,
            )
            val source = assertNotNull(store.listEntries().firstOrNull { it.label == "Source Server" })

            assertFalse(store.clearEntryReference(source.id, unknown.id))
            assertFalse(store.clearEntryReference(source.id, orphan.id))
            assertFalse(store.clearEntryReference(source.id, "missing-field"))
            assertTrue(store.listEntries(query = "opaque-unknown-value").isEmpty())
            assertTrue(store.listEntries(query = "opaque-orphan-value").isEmpty())

            assertTrue(store.clearEntryReference(source.id, reference.id))
            val updated = assertNotNull(store.liveEntry(source.id))
            assertEquals("", updated.customFields.single { it.id == reference.id }.value)
            assertEquals(unknown, updated.customFields.single { it.id == unknown.id })
            assertEquals(orphan, updated.customFields.single { it.id == orphan.id })
            assertEquals(
                EntryReferenceStatus.EMPTY,
                store.resolveEntryReference(
                    updated.customFields.single { it.id == reference.id },
                    sourceTemplate.category,
                )?.status,
            )
            assertTrue(store.clearEntryReference(source.id, reference.id))
            assertEquals("Reference cleared.", store.statusMessage)
        }
    }

    @Test
    fun onlyLiveValuesInTheSourceCategoryGateTemplateFieldDeletionAndTypeChanges() {
        withStore("PasswordManagerAndroidStoredTemplateValueGateTests") { store ->
            val nameField = CategoryTemplate.defaultCategoryFields()
                .single { field -> field.name == "名称" }
            val referenceField = FieldTemplate(
                id = "stored-reference",
                name = "Owner",
                valueType = "fieldReference",
                targetCategory = "Accounts",
                targetFieldId = nameField.id,
            )
            assertTrue(store.addCategory("Accounts"))
            assertTrue(store.addCategory("Original", listOf(referenceField)))
            assertTrue(store.addCategory("Moved", listOf(referenceField)))
            val target = store.upsert(entryDraft(label = "Account", category = "Accounts"))
            val sourceField = CustomField(
                id = "source-value-instance",
                templateFieldId = referenceField.id,
                name = referenceField.name,
                value = target.id,
            )
            val source = store.upsert(
                entryDraft(
                    label = "Source",
                    category = "Original",
                    customFields = listOf(sourceField),
                )
            )

            assertEquals(setOf(referenceField.id), store.categoryTemplateStoredValueFieldIds(" original "))
            store.delete(target.id)
            assertEquals(
                setOf(referenceField.id),
                store.categoryTemplateStoredValueFieldIds("Original"),
                "Deleting only the target keeps the live source relationship stored",
            )

            assertTrue(store.clearFieldReference(source.id, sourceField.id))
            assertTrue(store.categoryTemplateStoredValueFieldIds("Original").isEmpty())

            store.upsert(
                draft = entryDraft(
                    label = source.label,
                    category = "Original",
                    customFields = listOf(sourceField),
                ),
                editingId = source.id,
            )
            store.delete(source.id)
            assertTrue(store.categoryTemplateStoredValueFieldIds("Original").isEmpty())

            val movedSource = store.upsert(
                entryDraft(
                    label = "Moved source",
                    category = "Moved",
                    customFields = listOf(sourceField.copy(id = "moved-value-instance")),
                )
            )
            assertNotNull(store.liveEntry(movedSource.id))
            assertTrue(store.categoryTemplateStoredValueFieldIds("Original").isEmpty())

            assertTrue(store.updateCategoryTemplate("Original", requestedCustomFields = emptyList()))
            val updatedTemplate = assertNotNull(store.categoryTemplate("Original"))
            assertTrue(updatedTemplate.fields.none { field -> field.id == referenceField.id })
        }
    }

    private fun categoryTemplate(category: String): CategoryTemplate =
        CategoryTemplate(
            category = category,
            fields = listOf(
                FieldTemplate(id = SHARED_TEXT_TEMPLATE_ID, name = "Notes"),
                FieldTemplate(
                    id = SHARED_REFERENCE_TEMPLATE_ID,
                    name = "Owner",
                    valueType = "entryReference",
                    targetCategory = "Accounts",
                ),
                FieldTemplate(
                    id = "future-template-id",
                    name = "Future",
                    valueType = "futureReferenceV3",
                ),
            ),
        )

    private fun referenceTemplateField(): FieldTemplate =
        FieldTemplate(
            id = "reference-template",
            name = "Owner",
            valueType = "entryReference",
            targetCategory = "Accounts",
        )

    private fun referenceValue(template: FieldTemplate, targetId: String): CustomField =
        CustomField(
            templateFieldId = template.id,
            name = template.name,
            value = targetId,
        )

    private fun entryDraft(
        label: String,
        category: String,
        customFields: List<CustomField> = emptyList(),
        credential: CredentialPayload = CredentialPayload(),
    ): EntryDraft =
        EntryDraft(
            label = label,
            type = VaultEntryType.CREDENTIAL,
            category = category,
            tags = emptyList(),
            customFields = customFields,
            credential = credential,
        )

    private fun vaultEntry(
        id: String,
        label: String,
        category: String,
        customFields: List<CustomField>,
    ): VaultEntry =
        VaultEntry(
            id = id,
            label = label,
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(CredentialPayload(category = category)),
            customFields = customFields,
        )

    private fun importEntry(
        store: VaultStore,
        entry: VaultEntry,
        template: CategoryTemplate,
    ) {
        val export = ScopedVaultExport(
            scope = ScopedExportScope.ITEM,
            item = entry,
            categoryTemplates = listOf(template),
        )
        assertTrue(
            store.importScopedExportJson(
                raw = VaultJson.encodeScopedExport(export),
                strategy = ImportConflictStrategy.KEEP_COPY,
            )
        )
    }

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

    private companion object {
        const val SHARED_TEXT_TEMPLATE_ID = "shared-legacy-text"
        const val SHARED_REFERENCE_TEMPLATE_ID = "shared-legacy-reference"
    }
}
