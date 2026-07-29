package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CredentialPayload
import life.devops.passwordmanager.model.CategorySyncState
import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CategoryTypePreset
import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EncryptedPayloadRecord
import life.devops.passwordmanager.model.FieldTemplate
import life.devops.passwordmanager.model.ScopedExportScope
import life.devops.passwordmanager.model.ScopedVaultExport
import life.devops.passwordmanager.model.SecuritySettings
import life.devops.passwordmanager.model.ServerPayload
import life.devops.passwordmanager.model.ServiceAccount
import life.devops.passwordmanager.model.ServicePayload
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import life.devops.passwordmanager.model.VaultSnapshot
import org.json.JSONObject
import java.io.File
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VaultJsonTest {
    @Test
    fun sharedFieldReferenceFixturesRemainLossless() {
        val reference = VaultJson.decodeSnapshot(contractFixture("snapshot-entry-reference.json"))
        val referenceRoundTrip = VaultJson.decodeSnapshot(VaultJson.encodeSnapshot(reference))
        val source = referenceRoundTrip.entries.single { it.label == "Production Server" }
        val owner = referenceRoundTrip.categoryTemplates
            .single { it.category == "Servers" }
            .fields.single { it.name == "Owner" }

        assertEquals("harmony_target_01", referenceRoundTrip.entries.single { it.label == "Production Account" }.id)
        assertEquals("harmony_field_01", source.customFields.first().id)
        assertEquals(owner.id, source.customFields.first().templateFieldId)
        assertEquals("harmony_target_01", source.customFields.first().value)
        assertEquals("entryReference", owner.valueType)
        assertEquals("Accounts", owner.targetCategory)

        val legacy = VaultJson.decodeSnapshot(contractFixture("snapshot-legacy-text.json"))
        assertEquals("template_owner_team", legacy.categoryTemplates.single().fields.single().id)
        assertEquals("text", legacy.categoryTemplates.single().fields.single().valueType)
        assertEquals("", legacy.entries.single().customFields.single().templateFieldId)

        val emptySlug = VaultJson.decodeSnapshot(contractFixture("snapshot-legacy-empty-slug.json"))
        assertEquals(
            listOf("template_u_f09f9880", "template_u_212121"),
            emptySlug.categoryTemplates.single().fields.map { it.id },
        )
        assertEquals(
            emptySlug,
            VaultJson.decodeSnapshot(VaultJson.encodeSnapshot(emptySlug)),
        )

        val unknown = VaultJson.decodeSnapshot(contractFixture("snapshot-unknown-value-type.json"))
        val unknownRoundTrip = VaultJson.decodeSnapshot(VaultJson.encodeSnapshot(unknown))
        assertEquals("futureLink", unknownRoundTrip.categoryTemplates.single().fields.single().valueType)

        listOf(
            "scoped-item-entry-reference.json",
            "scoped-category-entry-reference.json",
        ).forEach { name ->
            val scoped = VaultJson.decodeScopedExport(contractFixture(name))
            val includedEntries = listOfNotNull(scoped.item) + scoped.items.orEmpty()
            assertEquals(2, scoped.version)
            assertEquals(listOf("Servers"), scoped.categoryTemplates.map { it.category })
            assertTrue(includedEntries.flatMap { it.customFields }.any { it.value == "harmony_target_01" })
            assertTrue(includedEntries.none { it.id == "harmony_target_01" })
        }
    }

    @Test
    fun snapshotRoundTripsCredentialServerServiceAndTombstone() {
        val snapshot = VaultSnapshot(
            entries = listOf(
                VaultEntry(
                    id = "11111111-2222-3333-4444-555555555555",
                    label = "Credential",
                    type = VaultEntryType.CREDENTIAL,
                    payload = VaultPayload.Credential(
                        CredentialPayload(
                            username = "user",
                            password = "password",
                            accounts = listOf(ServiceAccount("alt-user", "alt-password", "ssh")),
                            accessKey = "access",
                            secretKey = "secret",
                            tags = listOf("tag"),
                            category = "Default",
                        )
                    ),
                    updatedBy = "test",
                ),
                VaultEntry(
                    id = "22222222-3333-4444-5555-666666666666",
                    label = "Server",
                    type = VaultEntryType.SERVER,
                    payload = VaultPayload.Server(
                        ServerPayload(
                            name = "server",
                            ipAddress = "10.0.0.2",
                            port = "22",
                            username = "root",
                            password = "server-password",
                            accounts = listOf(ServiceAccount("deploy", "deploy-password", "ci")),
                            tags = listOf("server"),
                            accountId = "11111111-2222-3333-4444-555555555555",
                            category = "Infra",
                        )
                    ),
                    updatedBy = "test",
                ),
                VaultEntry(
                    id = "33333333-4444-5555-6666-777777777777",
                    label = "Service",
                    type = VaultEntryType.SERVICE,
                    payload = VaultPayload.Service(
                        ServicePayload(
                            name = "service",
                            connectionAddress = "service.internal",
                            connectionPort = "443",
                            accountId = "11111111-2222-3333-4444-555555555555",
                            serverIds = listOf("22222222-3333-4444-5555-666666666666"),
                            accounts = listOf(ServiceAccount("svc", "svc-password", "note")),
                            tags = listOf("service"),
                            category = "Services",
                        )
                    ),
                    updatedBy = "test",
                ),
                VaultEntry(
                    id = "44444444-5555-6666-7777-888888888888",
                    label = "Deleted",
                    type = VaultEntryType.CREDENTIAL,
                    payload = VaultPayload.Credential(CredentialPayload(username = "deleted")),
                    isDeleted = true,
                    deletedAt = Instant.parse("2026-05-23T00:00:00Z"),
                    updatedBy = "test",
                ),
            ),
            categories = listOf("Default", "Infra", "Services"),
            categoryTemplates = listOf(
                CategoryTemplate(
                    category = "Infra",
                    fields = CategoryTemplate.fieldsForPreset(CategoryTypePreset.SERVER),
                )
            ),
            categoryStates = listOf(
                CategorySyncState(
                    name = "Deleted Category",
                    isDeleted = true,
                    updatedAt = Instant.parse("2026-05-23T00:09:00Z"),
                    version = mapOf("android-device" to 2, "mac-device" to 1),
                    updatedBy = "android-device",
                )
            ),
            tags = listOf("server", "service", "tag"),
            security = SecuritySettings(requireTotp = true, totpSecret = "JBSWY3DPEHPK3PXP"),
            syncStatus = "Idle",
            backupStatus = "No backup has run",
            updatedAt = Instant.parse("2026-05-23T00:10:00Z"),
        )

        val encoded = VaultJson.encodeSnapshot(snapshot)
        val decoded = VaultJson.decodeSnapshot(encoded)

        assertEquals(4, decoded.entries.size)
        assertEquals(snapshot.categories, decoded.categories)
        assertEquals("Infra", decoded.categoryTemplates.single().category)
        assertEquals(snapshot.categoryStates, decoded.categoryStates)
        assertEquals(listOf("名称", "备注", "IP地址", "端口", "关联账号"), decoded.categoryTemplates.single().fields.map { it.name })
        assertEquals(snapshot.tags, decoded.tags)
        assertEquals(snapshot.security, decoded.security)
        assertEquals("Idle", decoded.syncStatus)
        assertEquals(true, decoded.entries.last().isDeleted)
        assertEquals(Instant.parse("2026-05-23T00:00:00Z"), decoded.entries.last().deletedAt)
        val service = decoded.entries.first { it.type == VaultEntryType.SERVICE }.payload as VaultPayload.Service
        assertEquals("svc", service.value.accounts.first().username)
        val credential = decoded.entries.first { it.type == VaultEntryType.CREDENTIAL }.payload as VaultPayload.Credential
        assertEquals("alt-user", credential.value.accounts.first().username)
        val server = decoded.entries.first { it.type == VaultEntryType.SERVER }.payload as VaultPayload.Server
        assertEquals("deploy", server.value.accounts.first().username)
        val serviceJson = JSONObject(encoded)
            .getJSONArray("entries")
            .getJSONObject(2)
            .getJSONObject("payload")
            .getJSONObject("service")
        assertFalse(serviceJson.getJSONArray("accounts").getJSONObject(0).has("id"))
    }

    @Test
    fun legacySnapshotsDecodeWithoutTemplatesOrAccounts() {
        val raw = JSONObject()
            .put(
                "entries",
                org.json.JSONArray(
                    listOf(
                        JSONObject()
                            .put("id", "legacy-credential")
                            .put("label", "Legacy Credential")
                            .put("type", "credential")
                            .put(
                                "payload",
                                JSONObject()
                                    .put(
                                        "credential",
                                        JSONObject()
                                            .put("username", "legacy")
                                            .put("password", "password")
                                            .put("category", "Legacy")
                                    )
                            ),
                        JSONObject()
                            .put("id", "legacy-server")
                            .put("label", "Legacy Server")
                            .put("type", "server")
                            .put(
                                "payload",
                                JSONObject()
                                    .put(
                                        "server",
                                        JSONObject()
                                            .put("name", "legacy-server")
                                            .put("ipAddress", "10.0.0.1")
                                            .put("category", "Legacy")
                                    )
                            )
                    )
                )
            )
            .put("categories", org.json.JSONArray(listOf("Legacy")))
            .toString()

        val decoded = VaultJson.decodeSnapshot(raw)
        val credential = decoded.entries.first { it.type == VaultEntryType.CREDENTIAL }.payload as VaultPayload.Credential
        val server = decoded.entries.first { it.type == VaultEntryType.SERVER }.payload as VaultPayload.Server

        assertEquals(emptyList(), decoded.categoryTemplates)
        assertEquals(emptyList(), credential.value.accounts)
        assertEquals(emptyList(), server.value.accounts)
        assertEquals("android", decoded.entries.first { it.type == VaultEntryType.CREDENTIAL }.updatedBy)
        assertEquals("android", decoded.entries.first { it.type == VaultEntryType.SERVER }.updatedBy)
    }

    @Test
    fun legacyFieldContractDefaultsAreDeterministic() {
        val raw = JSONObject()
            .put(
                "entries",
                org.json.JSONArray(
                    listOf(
                        JSONObject()
                            .put("id", "Legacy-Entry")
                            .put("label", "Legacy")
                            .put("type", "credential")
                            .put(
                                "payload",
                                JSONObject()
                                    .put(
                                        "credential",
                                        JSONObject().put("category", "Infra")
                                    )
                            )
                            .put(
                                "customFields",
                                org.json.JSONArray(
                                    listOf(
                                        JSONObject()
                                            .put("id", "Legacy-Custom-Field")
                                            .put("name", "Owner")
                                            .put("value", "legacy-value")
                                    )
                                )
                            )
                    )
                )
            )
            .put(
                "categoryTemplates",
                org.json.JSONArray(
                    listOf(
                        JSONObject()
                            .put("category", "Infra")
                            .put(
                                "fields",
                                org.json.JSONArray(
                                    listOf(
                                        JSONObject().put("id", "").put("name", "名称"),
                                        JSONObject().put("name", "备注"),
                                        JSONObject().put("name", "Owner"),
                                    )
                                )
                            ),
                    )
                )
            )
            .toString()

        val decoded = VaultJson.decodeSnapshot(raw)
        val fields = decoded.categoryTemplates.single().fields
        val customField = decoded.entries.single().customFields.single()

        assertEquals(listOf("名称", "备注", "Owner"), fields.map { it.name })
        assertEquals(listOf("template_名称", "template_备注", "template_owner"), fields.map { it.id })
        assertTrue(fields.all { it.valueType == "text" })
        assertTrue(fields.all { it.targetCategory.isEmpty() })
        assertEquals("", customField.templateFieldId)
        assertEquals("Legacy-Entry", decoded.entries.single().id)
        assertEquals("Legacy-Custom-Field", customField.id)
    }

    @Test
    fun referenceFieldContractRoundTripsWithoutChangingOpaqueIds() {
        val snapshot = VaultSnapshot(
            entries = listOf(
                VaultEntry(
                    id = "Entry-MixedCase-ID",
                    label = "Server",
                    type = VaultEntryType.CREDENTIAL,
                    payload = VaultPayload.Credential(CredentialPayload(category = "Servers")),
                    customFields = listOf(
                        CustomField(
                            id = "Custom-MixedCase-ID",
                            templateFieldId = "Template-Owner-ID",
                            name = "Owner",
                            value = "Account-MixedCase-ID",
                        )
                    ),
                )
            ),
            categoryTemplates = listOf(
                CategoryTemplate(
                    category = "Servers",
                    fields = listOf(
                        FieldTemplate(
                            id = "Template-Owner-ID",
                            name = "Owner",
                            valueType = "entryReference",
                            targetCategory = "Accounts",
                        )
                    ),
                )
            ),
        )

        val encoded = VaultJson.encodeSnapshot(snapshot)
        val decoded = VaultJson.decodeSnapshot(encoded)
        val decodedEntry = decoded.entries.single()
        val decodedField = decodedEntry.customFields.single()
        val decodedTemplateField = decoded.categoryTemplates.single().fields.single()

        assertEquals("Entry-MixedCase-ID", decodedEntry.id)
        assertEquals("Custom-MixedCase-ID", decodedField.id)
        assertEquals("Template-Owner-ID", decodedField.templateFieldId)
        assertEquals("Account-MixedCase-ID", decodedField.value)
        assertEquals("Template-Owner-ID", decodedTemplateField.id)
        assertEquals("entryReference", decodedTemplateField.valueType)
        assertEquals("Accounts", decodedTemplateField.targetCategory)
        assertEquals(
            "Template-Owner-ID",
            JSONObject(encoded)
                .getJSONArray("entries")
                .getJSONObject(0)
                .getJSONArray("customFields")
                .getJSONObject(0)
                .getString("templateFieldId"),
        )
    }

    @Test
    fun unknownFieldValueTypeIsPreservedAcrossRoundTrip() {
        val snapshot = VaultSnapshot(
            categoryTemplates = listOf(
                CategoryTemplate(
                    category = "Future",
                    fields = listOf(
                        FieldTemplate(
                            id = "future-template-id",
                            name = "Future Field",
                            valueType = "futureRelationV3",
                            targetCategory = "Targets",
                        )
                    ),
                )
            ),
        )

        val decoded = VaultJson.decodeSnapshot(VaultJson.encodeSnapshot(snapshot))
            .categoryTemplates.single().fields.single()

        assertEquals("futureRelationV3", decoded.valueType)
        assertEquals("Targets", decoded.targetCategory)
    }

    @Test
    fun snapshotCanonicalizesUuidIdentifiersToLowercase() {
        val snapshot = VaultSnapshot(
            entries = listOf(
                VaultEntry(
                    id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                    label = "Credential",
                    type = VaultEntryType.CREDENTIAL,
                    payload = VaultPayload.Credential(CredentialPayload(username = "user")),
                    customFields = listOf(
                        CustomField(
                            id = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                            name = "Field",
                            value = "Value",
                        )
                    ),
                    updatedBy = "test",
                )
            ),
            updatedAt = Instant.parse("2026-05-23T00:10:00Z"),
        )

        val encoded = VaultJson.encodeSnapshot(snapshot)
        val entryJson = JSONObject(encoded).getJSONArray("entries").getJSONObject(0)
        val decoded = VaultJson.decodeSnapshot(encoded).entries.single()

        assertEquals("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", entryJson.getString("id"))
        assertEquals("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", entryJson.getJSONArray("customFields").getJSONObject(0).getString("id"))
        assertEquals("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", decoded.id)
        assertEquals("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", decoded.customFields.single().id)
    }

    @Test
    fun scopedExportAcceptsFlutterDirectPayloadShape() {
        val raw = JSONObject()
            .put("version", 1)
            .put("scope", "item")
            .put("exportedAt", "2026-05-23T00:10:00Z")
            .put(
                "item",
                JSONObject()
                    .put("id", "flutter-credential-id")
                    .put("label", "Flutter Credential")
                    .put("type", "credential")
                    .put("category", "Mobile")
                    .put("createdAt", "2026-05-23T00:00:00Z")
                    .put("updatedAt", "2026-05-23T00:01:00Z")
                    .put("version", JSONObject().put("flutter", 1))
                    .put("updatedBy", "flutter")
                    .put(
                        "payload",
                        JSONObject()
                            .put("username", "flutter-user")
                            .put("password", "flutter-password")
                            .put("token", "")
                            .put("appId", "")
                            .put("accessKey", "")
                            .put("secretKey", "")
                            .put("notes", "")
                            .put("tags", org.json.JSONArray(listOf("mobile")))
                            .put("category", "Mobile")
                    )
            )
            .toString()

        val decoded = VaultJson.decodeScopedExport(raw)
        val entry = decoded.item ?: error("Expected item")
        val credential = (entry.payload as VaultPayload.Credential).value

        assertEquals("Flutter Credential", entry.label)
        assertEquals("Mobile", credential.category)
        assertEquals(listOf("mobile"), credential.tags)
        assertEquals("flutter-user", credential.username)
        assertEquals("flutter-password", credential.password)
        assertEquals(1, decoded.version)
        assertEquals(emptyList(), decoded.categoryTemplates)
    }

    @Test
    fun scopedVersionTwoRoundTripsCategoryTemplates() {
        val template = CategoryTemplate(
            category = "Servers",
            fields = listOf(
                FieldTemplate(
                    id = "template-owner",
                    name = "Owner",
                    valueType = "entryReference",
                    targetCategory = "Accounts",
                )
            ),
        )
        val export = ScopedVaultExport(
            scope = ScopedExportScope.CATEGORY,
            category = "Servers",
            items = emptyList(),
            categoryTemplates = listOf(template),
        )

        val encoded = VaultJson.encodeScopedExport(export)
        val decoded = VaultJson.decodeScopedExport(encoded)

        assertEquals(2, JSONObject(encoded).getInt("version"))
        assertEquals(2, decoded.version)
        assertEquals(listOf(template), decoded.categoryTemplates)
    }

    @Test
    fun scopedImportRejectsFullVaultJsonInsteadOfImportingZeroItems() {
        val error = assertFailsWith<IllegalArgumentException> {
            VaultJson.decodeScopedExport(
                JSONObject()
                    .put("version", 2)
                    .put("exportedAt", "2026-05-23T00:10:00Z")
                    .put("masterKey", JSONObject())
                    .put("items", org.json.JSONArray())
                    .toString()
            )
        }

        assertTrue(error.message.orEmpty().contains("full vault import"))
    }

    @Test
    fun importSnapshotAcceptsFlutterEncryptedFullExportShape() {
        val crypto = AndroidVaultCrypto()
        val password = "flutter-master-password"
        val masterKey = crypto.makeMasterKeyRecord(password)
        val recordKey = crypto.deriveKey(password, masterKey.saltBase64, masterKey.iterations)
        val metadataKey = crypto.deriveKey(
            password,
            masterKey.metadataSaltBase64 ?: masterKey.saltBase64,
            masterKey.metadataIterations ?: masterKey.iterations,
        )
        val encryptedPayload = crypto.encrypt(
            JSONObject()
                .put("username", "full-user")
                .put("password", "full-password")
                .put("token", "")
                .put("appId", "")
                .put("accessKey", "")
                .put("secretKey", "")
                .put("notes", "from Flutter full export")
                .put("tags", org.json.JSONArray(listOf("flutter", "full")))
                .put("category", "Imported")
                .toString()
                .toByteArray(Charsets.UTF_8),
            recordKey,
        )
        val encryptedMetadata = crypto.encrypt(
            JSONObject()
                .put("schemaVersion", 1)
                .put("label", "Flutter Full Credential")
                .put("type", "credential")
                .put("createdAt", "2026-05-23T00:00:00Z")
                .put("updatedAt", "2026-05-23T00:01:00Z")
                .put("version", JSONObject().put("flutter", 2))
                .put("updatedBy", "flutter")
                .put("isDeleted", false)
                .put("deletedAt", JSONObject.NULL)
                .put("category", "Imported")
                .put("tags", org.json.JSONArray(listOf("flutter", "full")))
                .toString()
                .toByteArray(Charsets.UTF_8),
            metadataKey,
        )
        val encryptedVaultMetadata = crypto.encrypt(
            JSONObject()
                .put("categories", org.json.JSONArray(listOf("Imported", "Manual Only")))
                .put("tags", org.json.JSONArray(listOf("flutter", "full", "manual")))
                .put("sortOrder", "updatedDesc")
                .put("tagsUpdatedAt", 0)
                .put("categoriesUpdatedAt", 0)
                .put("recordKeyMetadataMigrated", false)
                .toString()
                .toByteArray(Charsets.UTF_8),
            metadataKey,
        )
        val raw = JSONObject()
            .put("version", 2)
            .put("exportedAt", "2026-05-23T00:10:00Z")
            .put(
                "masterKey",
                JSONObject()
                    .put("salt", masterKey.saltBase64)
                    .put("iterations", masterKey.iterations)
                    .put("verifier", masterKey.verifierBase64)
                    .put("metadataSalt", masterKey.metadataSaltBase64)
                    .put("metadataIterations", masterKey.metadataIterations)
            )
            .put(
                "metadataRecord",
                JSONObject()
                    .put("encryptedPayload", encryptedVaultMetadata.toTestJson())
                    .put("kdfSalt", masterKey.metadataSaltBase64)
                    .put("kdfIterations", masterKey.metadataIterations)
            )
            .put(
                "items",
                org.json.JSONArray(
                    listOf(
                        JSONObject()
                            .put("id", "flutter-full-id")
                            .put("encryptedPayload", encryptedPayload.toTestJson())
                            .put("encryptedMetadata", encryptedMetadata.toTestJson())
                            .put("kdfSalt", masterKey.saltBase64)
                            .put("kdfIterations", masterKey.iterations)
                    )
                )
            )
            .toString()

        val decoded = VaultJson.decodeImportSnapshot(raw, password, crypto)
        val entry = decoded.entries.single()
        val credential = (entry.payload as VaultPayload.Credential).value

        assertEquals("Flutter Full Credential", entry.label)
        assertEquals("Imported", credential.category)
        assertEquals(listOf("flutter", "full"), credential.tags)
        assertEquals("full-user", credential.username)
        assertEquals("full-password", credential.password)
        assertEquals(listOf("Imported", "Manual Only"), decoded.categories)
        assertEquals(listOf("flutter", "full", "manual"), decoded.tags)
        assertTrue(decoded.syncStatus.contains("Flutter"))
    }

    private fun EncryptedPayloadRecord.toTestJson(): JSONObject =
        JSONObject()
            .put("ciphertext", ciphertext)
            .put("nonce", nonce)
            .put("mac", mac)
            .put("version", version)

    private fun contractFixture(name: String): String {
        val fixture = generateSequence(File(System.getProperty("user.dir").orEmpty())) { current ->
            current.parentFile
        }
            .take(8)
            .map { root -> File(root, "fixtures/vault-contract/v1/$name") }
            .firstOrNull(File::isFile)
        return fixture?.readText()
            ?: error("Unable to locate vault contract fixture: $name")
    }
}
