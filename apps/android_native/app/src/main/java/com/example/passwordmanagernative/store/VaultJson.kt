package com.example.passwordmanagernative.store

import com.example.passwordmanagernative.model.CredentialPayload
import com.example.passwordmanagernative.model.CustomField
import com.example.passwordmanagernative.model.EncryptedPayloadRecord
import com.example.passwordmanagernative.model.MasterKeyRecord
import com.example.passwordmanagernative.model.SecuritySettings
import com.example.passwordmanagernative.model.ServerPayload
import com.example.passwordmanagernative.model.ServiceAccount
import com.example.passwordmanagernative.model.ServicePayload
import com.example.passwordmanagernative.model.ScopedExportScope
import com.example.passwordmanagernative.model.ScopedVaultExport
import com.example.passwordmanagernative.model.VaultEntry
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultPayload
import com.example.passwordmanagernative.model.VaultPersistenceEnvelope
import com.example.passwordmanagernative.model.VaultSnapshot
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONObject.NULL
import java.time.Instant
import java.util.Locale
import java.util.UUID

object VaultJson {
    fun encodeEnvelope(envelope: VaultPersistenceEnvelope): String =
        JSONObject()
            .put("schemaVersion", envelope.schemaVersion)
            .put("masterKeyRecord", envelope.masterKeyRecord?.toJson())
            .put("encryptedVault", envelope.encryptedVault?.toJson())
            .put("updatedAt", envelope.updatedAt.toString())
            .toString(2)

    fun decodeEnvelope(raw: String): VaultPersistenceEnvelope {
        val json = JSONObject(raw)
        val masterKey = json.optJSONObject("masterKeyRecord")?.toMasterKeyRecord()
        val encryptedVault = json.optJSONObject("encryptedVault")?.toEncryptedPayloadRecord()
        return VaultPersistenceEnvelope(
            schemaVersion = json.optInt("schemaVersion", 1),
            masterKeyRecord = masterKey,
            encryptedVault = encryptedVault,
            updatedAt = json.optInstant("updatedAt") ?: Instant.now(),
        )
    }

    fun encodeSnapshot(snapshot: VaultSnapshot): String =
        JSONObject()
            .put("entries", JSONArray(snapshot.entries.map { it.toJson() }))
            .put("categories", JSONArray(snapshot.categories))
            .put("tags", JSONArray(snapshot.tags))
            .put("security", snapshot.security.toJson())
            .put("syncStatus", snapshot.syncStatus)
            .put("backupStatus", snapshot.backupStatus)
            .put("updatedAt", snapshot.updatedAt.toString())
            .toString()

    fun decodeSnapshot(raw: String): VaultSnapshot {
        val json = JSONObject(raw)
        return VaultSnapshot(
            entries = json.optJSONArray("entries").toVaultEntryList(),
            categories = json.optJSONArray("categories").toStringList(),
            tags = json.optJSONArray("tags").toStringList(),
            security = json.optJSONObject("security")?.toSecuritySettings() ?: SecuritySettings(),
            syncStatus = json.optString("syncStatus", "Not configured"),
            backupStatus = json.optString("backupStatus", json.optString("lastBackupStatus", "No backup has run")),
            updatedAt = json.optInstant("updatedAt") ?: Instant.now(),
        )
    }

    fun decodeImportSnapshot(
        raw: String,
        masterPassword: String,
        crypto: AndroidVaultCrypto,
    ): VaultSnapshot {
        val json = JSONObject(raw)
        return when {
            json.has("entries") -> decodeSnapshot(raw)
            json.has("masterKey") || json.has("metadataRecord") -> {
                require(json.has("items")) {
                    "Full Flutter export JSON is missing items. Export the full vault again from Flutter and make sure the top-level JSON contains items."
                }
                decodeFlutterEncryptedExport(json, masterPassword, crypto)
            }
            else -> decodeSnapshot(raw)
        }
    }

    fun encodeScopedExport(export: ScopedVaultExport): String =
        JSONObject()
            .put("version", export.version)
            .put("scope", export.scope.name.lowercase())
            .put("exportedAt", export.exportedAt.toString())
            .put("item", export.item?.toJson() ?: NULL)
            .put("category", export.category ?: NULL)
            .put("items", export.items?.let { JSONArray(it.map { entry -> entry.toJson() }) } ?: NULL)
            .toString(2)

    fun decodeScopedExport(raw: String): ScopedVaultExport {
        val json = JSONObject(raw)
        val scope = when (json.optString("scope")) {
            "category" -> ScopedExportScope.CATEGORY
            "item" -> ScopedExportScope.ITEM
            else -> throw IllegalArgumentException("This JSON is not an item/category export. Use full vault import for full exports.")
        }
        val item = when (scope) {
            ScopedExportScope.ITEM -> json.optJSONObject("item")
                ?: throw IllegalArgumentException("Item export JSON is missing item data.")
            ScopedExportScope.CATEGORY -> null
        }
        val items = when (scope) {
            ScopedExportScope.ITEM -> null
            ScopedExportScope.CATEGORY -> json.optJSONArray("items")
                ?: throw IllegalArgumentException("Category export JSON is missing item list.")
        }
        return ScopedVaultExport(
            version = json.optInt("version", 1),
            scope = scope,
            exportedAt = json.optInstant("exportedAt") ?: Instant.now(),
            item = item?.toVaultEntry(),
            category = json.optNullableString("category"),
            items = items.toVaultEntryList(),
        )
    }

    private fun MasterKeyRecord.toJson(): JSONObject =
        JSONObject()
            .put("saltBase64", saltBase64)
            .put("iterations", iterations)
            .put("verifierBase64", verifierBase64)
            .put("metadataSaltBase64", metadataSaltBase64 ?: NULL)
            .put("metadataIterations", metadataIterations ?: NULL)

    private fun JSONObject.toMasterKeyRecord(): MasterKeyRecord =
        MasterKeyRecord(
            saltBase64 = optString("saltBase64"),
            iterations = optInt("iterations"),
            verifierBase64 = optString("verifierBase64"),
            metadataSaltBase64 = optNullableString("metadataSaltBase64"),
            metadataIterations = if (has("metadataIterations") && !isNull("metadataIterations")) {
                optInt("metadataIterations")
            } else {
                null
            },
        )

    private fun JSONObject.toFlutterMasterKeyRecord(): MasterKeyRecord =
        MasterKeyRecord(
            saltBase64 = optString("salt", optString("saltBase64")),
            iterations = optInt("iterations", AndroidVaultCrypto.DEFAULT_ITERATIONS),
            verifierBase64 = optString("verifier", optString("verifierBase64")),
            metadataSaltBase64 = optNullableString("metadataSalt") ?: optNullableString("metadataSaltBase64"),
            metadataIterations = if (has("metadataIterations") && !isNull("metadataIterations")) {
                optInt("metadataIterations")
            } else {
                null
            },
        )

    private fun EncryptedPayloadRecord.toJson(): JSONObject =
        JSONObject()
            .put("ciphertext", ciphertext)
            .put("nonce", nonce)
            .put("mac", mac)
            .put("version", version)

    private fun JSONObject.toEncryptedPayloadRecord(): EncryptedPayloadRecord =
        EncryptedPayloadRecord(
            ciphertext = optString("ciphertext"),
            nonce = optString("nonce"),
            mac = optString("mac"),
            version = optInt("version", 1),
        )

    private fun VaultEntry.toJson(): JSONObject =
        JSONObject()
            .put("id", id.canonicalUuidString())
            .put("label", label)
            .put("type", type.name.lowercase())
            .put("payload", payload.toJson())
            .put("customFields", JSONArray(customFields.map { it.toJson() }))
            .put("createdAt", createdAt.toString())
            .put("updatedAt", updatedAt.toString())
            .put("version", JSONObject(version))
            .put("updatedBy", updatedBy)
            .put("isDeleted", isDeleted)
            .put("deletedAt", deletedAt?.toString() ?: NULL)

    private fun JSONObject.toVaultEntry(): VaultEntry {
        val type = when (optString("type", "credential")) {
            "server" -> VaultEntryType.SERVER
            "service" -> VaultEntryType.SERVICE
            else -> VaultEntryType.CREDENTIAL
        }
        return VaultEntry(
            id = optString("id").canonicalUuidString().ifBlank { UUID.randomUUID().toString() },
            label = optString("label"),
            type = type,
            payload = optJSONObject("payload").toVaultPayload(type),
            customFields = optJSONArray("customFields").toCustomFieldList(),
            createdAt = optInstant("createdAt") ?: Instant.now(),
            updatedAt = optInstant("updatedAt") ?: Instant.now(),
            version = optJSONObject("version").toIntMap(),
            updatedBy = optString("updatedBy", "android-native"),
            isDeleted = optBoolean("isDeleted", false),
            deletedAt = optInstant("deletedAt"),
        )
    }

    private fun VaultPayload.toJson(): JSONObject =
        when (this) {
            is VaultPayload.Credential -> JSONObject().put("credential", value.toJson())
            is VaultPayload.Server -> JSONObject().put("server", value.toJson())
            is VaultPayload.Service -> JSONObject().put("service", value.toJson())
        }

    private fun JSONObject?.toVaultPayload(type: VaultEntryType): VaultPayload {
        val payload = this ?: JSONObject()
        return when (type) {
            VaultEntryType.CREDENTIAL -> VaultPayload.Credential(
                (payload.optJSONObject("credential") ?: payload).toCredentialPayload()
            )
            VaultEntryType.SERVER -> VaultPayload.Server(
                (payload.optJSONObject("server") ?: payload).toServerPayload()
            )
            VaultEntryType.SERVICE -> VaultPayload.Service(
                (payload.optJSONObject("service") ?: payload).toServicePayload()
            )
        }
    }

    private fun CredentialPayload.toJson(): JSONObject =
        JSONObject()
            .put("username", username)
            .put("password", password)
            .put("token", token)
            .put("appId", appId)
            .put("accessKey", accessKey)
            .put("secretKey", secretKey)
            .put("notes", notes)
            .put("tags", JSONArray(tags))
            .put("category", category)

    private fun JSONObject?.toCredentialPayload(): CredentialPayload {
        val json = this ?: JSONObject()
        return CredentialPayload(
            username = json.optString("username"),
            password = json.optString("password"),
            token = json.optString("token"),
            appId = json.optString("appId"),
            accessKey = json.optString("accessKey", json.optString("accessToken")),
            secretKey = json.optString("secretKey"),
            notes = json.optString("notes"),
            tags = json.optJSONArray("tags").toStringList(),
            category = json.optString("category"),
        )
    }

    private fun ServerPayload.toJson(): JSONObject =
        JSONObject()
            .put("name", name)
            .put("ipAddress", ipAddress)
            .put("port", port)
            .put("username", username)
            .put("password", password)
            .put("basicConfig", basicConfig)
            .put("operatingSystem", operatingSystem)
            .put("location", location)
            .put("notes", notes)
            .put("tags", JSONArray(tags))
            .put("accountId", accountId ?: NULL)
            .put("category", category)

    private fun JSONObject?.toServerPayload(): ServerPayload {
        val json = this ?: JSONObject()
        return ServerPayload(
            name = json.optString("name"),
            ipAddress = json.optString("ipAddress"),
            port = json.optString("port"),
            username = json.optString("username"),
            password = json.optString("password"),
            basicConfig = json.optString("basicConfig"),
            operatingSystem = json.optString("operatingSystem"),
            location = json.optString("location"),
            notes = json.optString("notes"),
            tags = json.optJSONArray("tags").toStringList(),
            accountId = json.optNullableString("accountId"),
            category = json.optString("category"),
        )
    }

    private fun ServicePayload.toJson(): JSONObject =
        JSONObject()
            .put("name", name)
            .put("connectionAddress", connectionAddress)
            .put("connectionPort", connectionPort)
            .put("accountId", accountId ?: NULL)
            .put("serverIds", JSONArray(serverIds))
            .put("accounts", JSONArray(accounts.map { it.toJson() }))
            .put("notes", notes)
            .put("tags", JSONArray(tags))
            .put("category", category)

    private fun JSONObject?.toServicePayload(): ServicePayload {
        val json = this ?: JSONObject()
        return ServicePayload(
            name = json.optString("name"),
            connectionAddress = json.optString("connectionAddress"),
            connectionPort = json.optString("connectionPort"),
            accountId = json.optNullableString("accountId"),
            serverIds = json.optJSONArray("serverIds").toStringList(),
            accounts = json.optJSONArray("accounts").toServiceAccountList(),
            notes = json.optString("notes"),
            tags = json.optJSONArray("tags").toStringList(),
            category = json.optString("category"),
        )
    }

    private fun ServiceAccount.toJson(): JSONObject =
        JSONObject()
            .put("username", username)
            .put("password", password)
            .put("note", note)

    private fun JSONObject.toServiceAccount(): ServiceAccount =
        ServiceAccount(
            username = optString("username"),
            password = optString("password"),
            note = optString("note"),
        )

    private fun CustomField.toJson(): JSONObject =
        JSONObject()
            .put("id", id.canonicalUuidString())
            .put("name", name)
            .put("value", value)

    private fun JSONObject.toCustomField(): CustomField =
        CustomField(
            id = optString("id").canonicalUuidString().ifBlank { UUID.randomUUID().toString() },
            name = optString("name"),
            value = optString("value"),
        )

    private fun SecuritySettings.toJson(): JSONObject =
        JSONObject()
            .put("requireTotp", requireTotp)
            .put("totpSecret", totpSecret)

    private fun JSONObject.toSecuritySettings(): SecuritySettings =
        SecuritySettings(
            requireTotp = optBoolean("requireTotp", false),
            totpSecret = optString("totpSecret"),
        )

    private fun JSONObject?.toIntMap(): Map<String, Int> {
        val json = this ?: return emptyMap()
        return json.keys().asSequence().associateWith { key -> json.optInt(key, 0) }
    }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { index -> optString(index).takeIf { it.isNotBlank() } }
    }

    private fun JSONArray?.toVaultEntryList(): List<VaultEntry> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { index -> optJSONObject(index)?.toVaultEntry() }
    }

    private fun JSONArray?.toServiceAccountList(): List<ServiceAccount> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { index -> optJSONObject(index)?.toServiceAccount() }
    }

    private fun JSONArray?.toCustomFieldList(): List<CustomField> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { index -> optJSONObject(index)?.toCustomField() }
    }

    private fun decodeFlutterEncryptedExport(
        json: JSONObject,
        masterPassword: String,
        crypto: AndroidVaultCrypto,
    ): VaultSnapshot {
        val masterKey = json.optJSONObject("masterKey")?.toFlutterMasterKeyRecord()
        val metadataKey = masterKey?.let { record ->
            runCatching {
                crypto.verify(masterPassword, record)
                crypto.deriveKey(
                    masterPassword,
                    record.metadataSaltBase64 ?: record.saltBase64,
                    record.metadataIterations ?: record.iterations,
                )
            }.getOrNull()
        }
        val entries = json.optJSONArray("items").toFlutterRecordEntries(
            masterPassword = masterPassword,
            metadataKey = metadataKey,
            crypto = crypto,
        )
        val vaultMetadata = json.optJSONObject("metadataRecord")
            ?.toFlutterVaultMetadata(masterPassword, metadataKey, crypto)
        val categories = vaultMetadata
            ?.optJSONArray("categories")
            .toStringList()
            .ifEmpty {
                entries.map { it.payload.category }
                    .filter { it.isNotBlank() }
                    .distinct()
                    .sorted()
            }
        val tags = vaultMetadata
            ?.optJSONArray("tags")
            .toStringList()
            .ifEmpty {
                entries.flatMap { it.payload.tags }
                    .filter { it.isNotBlank() }
                    .distinct()
                    .sorted()
            }
        return VaultSnapshot(
            entries = entries,
            categories = categories,
            tags = tags,
            security = SecuritySettings(),
            syncStatus = "Imported from Flutter export",
            backupStatus = "No backup has run",
            updatedAt = json.optInstant("exportedAt") ?: Instant.now(),
        )
    }

    private fun JSONArray?.toFlutterRecordEntries(
        masterPassword: String,
        metadataKey: ByteArray?,
        crypto: AndroidVaultCrypto,
    ): List<VaultEntry> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { index ->
            optJSONObject(index)?.toFlutterRecordEntry(masterPassword, metadataKey, crypto)
        }
    }

    private fun JSONObject.toFlutterRecordEntry(
        masterPassword: String,
        metadataKey: ByteArray?,
        crypto: AndroidVaultCrypto,
    ): VaultEntry {
        val recordKey = crypto.deriveKey(
            masterPassword,
            optString("kdfSalt"),
            optInt("kdfIterations", AndroidVaultCrypto.DEFAULT_ITERATIONS),
        )
        val metadata = decryptJsonObject(
            encrypted = optJSONObject("encryptedMetadata"),
            candidateKeys = listOfNotNull(metadataKey, recordKey),
            crypto = crypto,
        ) ?: legacyMetadataJson()
        val type = when (metadata.optString("type", "credential")) {
            "server" -> VaultEntryType.SERVER
            "service" -> VaultEntryType.SERVICE
            else -> VaultEntryType.CREDENTIAL
        }
        val payloadJson = decryptJsonObject(
            encrypted = optJSONObject("encryptedPayload"),
            candidateKeys = listOf(recordKey),
            crypto = crypto,
        ) ?: JSONObject()
        return VaultEntry(
            id = optString("id").canonicalUuidString().ifBlank { UUID.randomUUID().toString() },
            label = metadata.optString("label", optString("id")),
            type = type,
            payload = payloadJson.toVaultPayload(type),
            customFields = payloadJson.optJSONArray("customFields").toCustomFieldList(),
            createdAt = metadata.optInstant("createdAt") ?: Instant.now(),
            updatedAt = metadata.optInstant("updatedAt") ?: Instant.now(),
            version = metadata.optJSONObject("version").toIntMap(),
            updatedBy = metadata.optString("updatedBy", "flutter"),
            isDeleted = metadata.optBoolean("isDeleted", false),
            deletedAt = metadata.optInstant("deletedAt"),
        )
    }

    private fun JSONObject.toFlutterVaultMetadata(
        masterPassword: String,
        metadataKey: ByteArray?,
        crypto: AndroidVaultCrypto,
    ): JSONObject? {
        val recordKey = optNullableString("kdfSalt")?.let { salt ->
            runCatching {
                crypto.deriveKey(
                    masterPassword,
                    salt,
                    optInt("kdfIterations", AndroidVaultCrypto.DEFAULT_ITERATIONS),
                )
            }.getOrNull()
        }
        return decryptJsonObject(
            encrypted = optJSONObject("encryptedPayload"),
            candidateKeys = listOfNotNull(metadataKey, recordKey),
            crypto = crypto,
        )
    }

    private fun decryptJsonObject(
        encrypted: JSONObject?,
        candidateKeys: List<ByteArray>,
        crypto: AndroidVaultCrypto,
    ): JSONObject? {
        if (encrypted == null) return null
        val payload = encrypted.toEncryptedPayloadRecord()
        candidateKeys.forEach { key ->
            runCatching {
                JSONObject(crypto.decrypt(payload, key).toString(Charsets.UTF_8))
            }.getOrNull()?.let { return it }
        }
        return null
    }

    private fun JSONObject.legacyMetadataJson(): JSONObject =
        JSONObject()
            .put("label", optString("label"))
            .put("type", optString("type", "credential"))
            .put("createdAt", optString("createdAt"))
            .put("updatedAt", optString("updatedAt"))
            .put("version", optJSONObject("version") ?: JSONObject())
            .put("updatedBy", optString("updatedBy", "legacy"))
            .put("isDeleted", optBoolean("isDeleted", false))
            .put("deletedAt", optNullableString("deletedAt") ?: NULL)
            .put("category", optString("category"))
            .put("tags", optJSONArray("tags") ?: JSONArray())

    private fun JSONObject?.optInstant(name: String): Instant? {
        val value = this?.optNullableString(name) ?: return null
        return runCatching { Instant.parse(value) }.getOrNull()
    }

    private fun JSONObject?.optNullableString(name: String): String? {
        if (this == null || !has(name) || isNull(name)) return null
        return optString(name)
    }

    private fun String.canonicalUuidString(): String {
        val trimmed = trim()
        if (trimmed.isEmpty()) return trimmed
        return runCatching { UUID.fromString(trimmed).toString() }
            .getOrElse { trimmed.lowercase(Locale.ROOT) }
    }
}
