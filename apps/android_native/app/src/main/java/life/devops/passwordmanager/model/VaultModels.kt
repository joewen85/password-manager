package life.devops.passwordmanager.model

import java.time.Instant
import java.util.UUID

enum class VaultEntryType(val title: String) {
    CREDENTIAL("Credential"),
    SERVER("Server"),
    SERVICE("Service")
}

data class CredentialPayload(
    val username: String = "",
    val password: String = "",
    val accounts: List<ServiceAccount> = emptyList(),
    val token: String = "",
    val appId: String = "",
    val accessKey: String = "",
    val secretKey: String = "",
    val notes: String = "",
    val tags: List<String> = emptyList(),
    val category: String = "",
)

data class ServerPayload(
    val name: String = "",
    val ipAddress: String = "",
    val port: String = "",
    val username: String = "",
    val password: String = "",
    val accounts: List<ServiceAccount> = emptyList(),
    val basicConfig: String = "",
    val operatingSystem: String = "",
    val location: String = "",
    val notes: String = "",
    val tags: List<String> = emptyList(),
    val accountId: String? = null,
    val category: String = "",
)

data class SecuritySettings(
    val requireTotp: Boolean = false,
    val totpSecret: String = "",
)

data class CategorySyncState(
    val name: String,
    val isDeleted: Boolean = false,
    val updatedAt: Instant = Instant.now(),
    val version: Map<String, Int> = emptyMap(),
    val updatedBy: String = "",
)

data class VaultSnapshot(
    val entries: List<VaultEntry> = emptyList(),
    val categories: List<String> = emptyList(),
    val categoryTemplates: List<CategoryTemplate> = emptyList(),
    val categoryStates: List<CategorySyncState> = emptyList(),
    val tags: List<String> = emptyList(),
    val security: SecuritySettings = SecuritySettings(),
    val syncStatus: String = "Not configured",
    val backupStatus: String = "No backup has run",
    val updatedAt: Instant = Instant.now(),
)

data class ServiceAccount(
    val username: String = "",
    val password: String = "",
    val note: String = "",
)

data class ServicePayload(
    val name: String = "",
    val connectionAddress: String = "",
    val connectionPort: String = "",
    val accountId: String? = null,
    val serverIds: List<String> = emptyList(),
    val accounts: List<ServiceAccount> = emptyList(),
    val notes: String = "",
    val tags: List<String> = emptyList(),
    val category: String = "",
)

data class CustomField(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val value: String = "",
    val templateFieldId: String = "",
)

data class FieldTemplate(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val valueType: String = "text",
    val targetCategory: String = "",
    val targetFieldId: String = "",
)

data class CategoryTemplate(
    val category: String,
    val fields: List<FieldTemplate> = defaultCategoryFields(),
) {
    companion object {
        fun defaultCategoryFields(): List<FieldTemplate> =
            listOf(
                FieldTemplate(stableFieldId("名称"), "名称"),
                FieldTemplate(stableFieldId("备注"), "备注"),
            )

        fun fieldsForPreset(
            preset: CategoryTypePreset?,
            customFieldNames: List<String> = emptyList(),
        ): List<FieldTemplate> =
            (defaultCategoryFields() + preset.orEmptyFields().map { fieldName ->
                FieldTemplate(stableFieldId(fieldName), fieldName)
            } + customFieldNames.map { fieldName ->
                FieldTemplate(stableFieldId(fieldName), fieldName)
            })
                .filter { it.name.trim().isNotEmpty() }
                .distinctBy { it.name.trim().lowercase() }

        internal fun stableFieldId(name: String): String {
            val trimmed = name.trim()
            val normalized = trimmed.lowercase()
                .replace(Regex("""[^a-z0-9\u4e00-\u9fff]+"""), "_")
                .trim('_')
            val suffix = when {
                normalized.isNotEmpty() -> normalized
                trimmed.isEmpty() -> "empty"
                else -> "u_${trimmed.toByteArray(Charsets.UTF_8).joinToString("") { byte ->
                    (byte.toInt() and 0xff).toString(16).padStart(2, '0')
                }}"
            }
            return "template_$suffix"
        }

        private fun CategoryTypePreset?.orEmptyFields(): List<String> =
            this?.fields ?: emptyList()
    }
}

enum class CategoryTypePreset(val title: String, val fields: List<String>) {
    SERVER("服务器", listOf("IP地址", "端口", "关联账号")),
    SERVICE("服务", listOf("服务入口", "关联账号", "关联服务器")),
    ACCOUNT("账号", listOf("入口"));

    companion object {
        fun fromTitle(value: String): CategoryTypePreset? =
            entries.firstOrNull { it.title == value.trim() }
    }
}

sealed interface VaultPayload {
    val category: String
    val tags: List<String>

    data class Credential(val value: CredentialPayload) : VaultPayload {
        override val category: String = value.category
        override val tags: List<String> = value.tags
    }

    data class Server(val value: ServerPayload) : VaultPayload {
        override val category: String = value.category
        override val tags: List<String> = value.tags
    }

    data class Service(val value: ServicePayload) : VaultPayload {
        override val category: String = value.category
        override val tags: List<String> = value.tags
    }
}

data class VaultEntry(
    val id: String = UUID.randomUUID().toString(),
    val label: String,
    val type: VaultEntryType,
    val payload: VaultPayload,
    val customFields: List<CustomField> = emptyList(),
    val createdAt: Instant = Instant.now(),
    val updatedAt: Instant = Instant.now(),
    val version: Map<String, Int> = emptyMap(),
    val updatedBy: String = "android",
    val isDeleted: Boolean = false,
    val deletedAt: Instant? = null,
)

val String.safeExportName: String
    get() {
        val invalid = Regex("""[\\/:*?"<>|\s]+""")
        val safeName = trim()
            .split(invalid)
            .filter { it.isNotEmpty() }
            .joinToString("_")
        return safeName.ifEmpty { "untitled" }
    }

val VaultEntry.safeExportName: String
    get() = label.safeExportName

val VaultEntry.importMatchKey: String
    get() = listOf(
        type.name.lowercase(),
        label.trim().lowercase(),
        payload.category.trim().lowercase(),
    ).joinToString("|")

fun VaultEntry.copyForImport(id: String = UUID.randomUUID().toString(), updatedAt: Instant = Instant.now()): VaultEntry =
    copy(
        id = id,
        updatedAt = updatedAt,
        isDeleted = false,
        deletedAt = null,
    )

data class MasterKeyRecord(
    val saltBase64: String,
    val iterations: Int,
    val verifierBase64: String,
    val metadataSaltBase64: String? = null,
    val metadataIterations: Int? = null,
)

data class EncryptedPayloadRecord(
    val ciphertext: String,
    val nonce: String,
    val mac: String,
    val version: Int,
)

data class VaultPersistenceEnvelope(
    val schemaVersion: Int = 1,
    val masterKeyRecord: MasterKeyRecord? = null,
    val encryptedVault: EncryptedPayloadRecord? = null,
    val updatedAt: Instant = Instant.now(),
)

enum class ScopedExportScope {
    ITEM,
    CATEGORY
}

data class ScopedVaultExport(
    val version: Int = 2,
    val scope: ScopedExportScope,
    val exportedAt: Instant = Instant.now(),
    val item: VaultEntry? = null,
    val category: String? = null,
    val items: List<VaultEntry>? = null,
    val categoryTemplates: List<CategoryTemplate> = emptyList(),
)

enum class ImportConflictStrategy(val title: String) {
    KEEP_COPY("Keep Copy"),
    OVERWRITE("Overwrite"),
    SKIP("Skip")
}

data class EntryDraft(
    val label: String,
    val type: VaultEntryType,
    val category: String,
    val tags: List<String>,
    val customFields: List<CustomField> = emptyList(),
    val credential: CredentialPayload = CredentialPayload(),
    val server: ServerPayload = ServerPayload(),
    val service: ServicePayload = ServicePayload(),
) {
    fun toPayload(): VaultPayload = when (type) {
        VaultEntryType.CREDENTIAL -> VaultPayload.Credential(
            credential.copy(category = category, tags = tags)
        )
        VaultEntryType.SERVER -> VaultPayload.Server(
            server.copy(category = category, tags = tags)
        )
        VaultEntryType.SERVICE -> VaultPayload.Service(
            service.copy(category = category, tags = tags)
        )
    }
}
