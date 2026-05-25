package com.example.passwordmanagernative.store

import com.example.passwordmanagernative.model.CredentialPayload
import com.example.passwordmanagernative.model.EncryptedPayloadRecord
import com.example.passwordmanagernative.model.SecuritySettings
import com.example.passwordmanagernative.model.ServerPayload
import com.example.passwordmanagernative.model.ServiceAccount
import com.example.passwordmanagernative.model.ServicePayload
import com.example.passwordmanagernative.model.VaultEntry
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultPayload
import com.example.passwordmanagernative.model.VaultSnapshot
import org.json.JSONObject
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VaultJsonTest {
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
        assertEquals(snapshot.tags, decoded.tags)
        assertEquals(snapshot.security, decoded.security)
        assertEquals("Idle", decoded.syncStatus)
        assertEquals(true, decoded.entries.last().isDeleted)
        assertEquals(Instant.parse("2026-05-23T00:00:00Z"), decoded.entries.last().deletedAt)
        val service = decoded.entries.first { it.type == VaultEntryType.SERVICE }.payload as VaultPayload.Service
        assertEquals("svc", service.value.accounts.first().username)
        val serviceJson = JSONObject(encoded)
            .getJSONArray("entries")
            .getJSONObject(2)
            .getJSONObject("payload")
            .getJSONObject("service")
        assertFalse(serviceJson.getJSONArray("accounts").getJSONObject(0).has("id"))
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
}
