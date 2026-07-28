package life.devops.passwordmanager.store

import android.content.Context
import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CategoryTypePreset
import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.FieldTemplate
import life.devops.passwordmanager.model.ImportConflictStrategy
import life.devops.passwordmanager.model.MasterKeyRecord
import life.devops.passwordmanager.model.ScopedExportScope
import life.devops.passwordmanager.model.ScopedVaultExport
import life.devops.passwordmanager.model.SecuritySettings
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import life.devops.passwordmanager.model.VaultPersistenceEnvelope
import life.devops.passwordmanager.model.VaultSnapshot
import life.devops.passwordmanager.model.copyForImport
import life.devops.passwordmanager.model.importMatchKey
import life.devops.passwordmanager.model.mergeCustomFieldsForLegacyEditorSave
import life.devops.passwordmanager.sync.EncryptedRemoteSyncClient
import life.devops.passwordmanager.sync.RemoteSyncClient
import life.devops.passwordmanager.sync.SyncClientFactory
import life.devops.passwordmanager.sync.SyncLogEntry
import life.devops.passwordmanager.sync.SyncProviderType
import life.devops.passwordmanager.sync.SyncSettings
import life.devops.passwordmanager.sync.SyncSettingsRepository
import life.devops.passwordmanager.sync.VaultSyncCancelledException
import life.devops.passwordmanager.sync.VaultSyncEngine
import life.devops.passwordmanager.sync.VaultSyncEngineException
import life.devops.passwordmanager.sync.VaultSyncEngineResult
import life.devops.passwordmanager.sync.VaultSyncPayload
import java.time.Instant

data class BackupInfo(
    val fileName: String,
    val sizeBytes: Long,
    val modifiedAt: Instant,
)

private data class SyncLoopInput(
    val snapshot: VaultSnapshot,
    val settings: SyncSettings,
    val vaultKey: ByteArray,
    val masterKeyRecord: MasterKeyRecord?,
    val masterPassword: String,
)

class VaultStore(
    private val repository: FileVaultRepository,
    private val syncSettingsRepository: SyncSettingsRepository? = null,
    private val crypto: AndroidVaultCrypto = AndroidVaultCrypto(),
    private val totp: TotpService = TotpService(),
    private val syncClientFactory: SyncClientFactory = SyncClientFactory(),
    private val syncEngine: VaultSyncEngine = VaultSyncEngine(),
    ensureKeystoreWrappingKey: Boolean = false,
) {
    constructor(context: Context) : this(
        repository = FileVaultRepository.fromContext(context.applicationContext),
        syncSettingsRepository = SyncSettingsRepository.fromContext(context.applicationContext),
        ensureKeystoreWrappingKey = true,
    )

    var isUnlocked: Boolean = false
        private set
    var hasMasterKey: Boolean = false
        private set
    var requireTotp: Boolean = false
        private set
    var totpSecret: String = ""
        private set
    var syncStatus: String = "Not configured"
        private set
    var backupStatus: String = "No backup has run"
        private set
    var statusMessage: String? = null
        private set
    var syncSettings: SyncSettings = SyncSettings.defaults()
        private set

    private var masterPassword: String = ""
    private var masterKeyRecord: MasterKeyRecord? = null
    private var activeVaultKey: ByteArray? = null
    private val entries = mutableListOf<VaultEntry>()
    private val manualCategories = mutableSetOf<String>()
    private val categoryTemplates = mutableMapOf<String, CategoryTemplate>()
    private val manualTags = mutableSetOf<String>()
    @Volatile
    private var isSyncing = false
    @Volatile
    private var syncRequestedAgain = false
    @Volatile
    private var localChangeRevision = 0

    init {
        loadSyncSettings()
        loadEnvelopeMetadata()
        if (ensureKeystoreWrappingKey) {
            runCatching { crypto.ensureKeystoreWrappingKey() }
                .onFailure { statusMessage = "Android Keystore is unavailable: ${it.message}" }
        }
    }

    @Synchronized
    fun setupMasterPassword(password: String, confirmation: String): Boolean {
        if (password.isBlank() || password != confirmation) {
            statusMessage = "Master password is empty or confirmation does not match."
            return false
        }
        return runCatching {
            val record = crypto.makeMasterKeyRecord(password)
            val key = crypto.verify(password, record)
            masterPassword = password
            masterKeyRecord = record
            activeVaultKey = key
            hasMasterKey = true
            isUnlocked = true
            markLocalChangesForSync()
            saveSnapshot()
            statusMessage = "Vault initialized and encrypted locally."
            true
        }.getOrElse {
            statusMessage = it.message
            false
        }
    }

    @Synchronized
    fun unlock(password: String, totpCode: String = ""): Boolean {
        val record = masterKeyRecord ?: run {
            statusMessage = "No vault has been initialized."
            return false
        }
        if (requireTotp) {
            if (totpSecret.isBlank()) {
                statusMessage = "2FA secret is not configured."
                return false
            }
            if (!totp.verifyCode(totpSecret, totpCode)) {
                statusMessage = "2FA code is invalid."
                return false
            }
        }
        return runCatching {
            val key = crypto.verify(password, record)
            loadSnapshot(key)
            masterPassword = password
            activeVaultKey = key
            isUnlocked = true
            statusMessage = "Vault unlocked."
            true
        }.getOrElse {
            statusMessage = it.message
            false
        }
    }

    fun verifyMasterPassword(password: String): Boolean {
        val record = masterKeyRecord ?: run {
            statusMessage = "No vault has been initialized."
            return false
        }
        return runCatching {
            crypto.verify(password, record)
            true
        }.getOrElse {
            statusMessage = "Vault authentication failed."
            false
        }
    }

    @Synchronized
    fun lock() {
        isUnlocked = false
        masterPassword = ""
        activeVaultKey = null
    }

    fun listEntries(
        query: String = "",
        type: VaultEntryType? = null,
        category: String? = null,
        tag: String? = null,
    ): List<VaultEntry> {
        val searchTerms = parseVaultSearchTerms(query)
        return entries
            .asSequence()
            .filter { !it.isDeleted }
            .filter { type == null || it.type == type }
            .filter { category == null || it.payload.category == category }
            .filter { tag == null || it.payload.tags.contains(tag) }
            .filter {
                searchTerms.isEmpty() || it.matchesSearchTerms(searchTerms)
            }
            .sortedByDescending { it.updatedAt }
            .toList()
    }

    @Synchronized
    fun upsert(draft: EntryDraft, editingId: String? = null): VaultEntry {
        val now = Instant.now()
        val existingIndex = editingId?.let { id -> entries.indexOfFirst { it.id == id } } ?: -1
        val existingEntry = entries.getOrNull(existingIndex)
        val normalizedTags = draft.tags.map { it.trim() }.filter { it.isNotEmpty() }
        val normalizedCustomFields = draft.customFields
            .map { it.copy(name = it.name.trim(), value = it.value.trim()) }
            .filter { it.name.isNotBlank() || it.value.isNotBlank() }
        val normalizedDraft = draft.copy(
            category = draft.category.trim(),
            tags = normalizedTags,
            customFields = existingEntry?.let { current ->
                mergeCustomFieldsForLegacyEditorSave(
                    originalFields = current.customFields,
                    editedFields = normalizedCustomFields,
                    template = categoryTemplate(current.payload.category),
                )
            } ?: normalizedCustomFields,
        )
        val entry = if (existingIndex >= 0) {
            entries[existingIndex].copy(
                label = normalizedDraft.label,
                type = normalizedDraft.type,
                payload = normalizedDraft.toPayload(),
                customFields = normalizedDraft.customFields,
                updatedAt = now,
                isDeleted = false,
                deletedAt = null,
            ).markLocalEntryChange(syncSettings.deviceId, now)
        } else {
            VaultEntry(
                label = normalizedDraft.label,
                type = normalizedDraft.type,
                payload = normalizedDraft.toPayload(),
                customFields = normalizedDraft.customFields,
                createdAt = now,
                updatedAt = now,
            ).markLocalEntryChange(syncSettings.deviceId, now)
        }
        if (existingIndex >= 0) {
            entries[existingIndex] = entry
        } else {
            entries += entry
        }
        persistUnlockedSnapshot()
        return entry
    }

    @Synchronized
    fun delete(id: String) {
        val index = entries.indexOfFirst { it.id == id }
        if (index < 0) return
        val now = Instant.now()
        entries[index] = entries[index].copy(
            isDeleted = true,
            deletedAt = now,
            updatedAt = now,
        ).markLocalEntryChange(syncSettings.deviceId, now)
        persistUnlockedSnapshot()
    }

    fun categories(): List<String> =
        buildSet {
            addAll(manualCategories)
            addAll(categoryTemplates.keys)
            addAll(entries.filterNot { it.isDeleted }.map { it.payload.category })
        }
            .filter { it.isNotBlank() }
            .sorted()

    fun categoryTemplate(category: String): CategoryTemplate? {
        val normalized = category.trim()
        if (normalized.isBlank()) return null
        return categoryTemplates.entries
            .firstOrNull { it.key.equals(normalized, ignoreCase = true) }
            ?.value
    }

    fun tags(): List<String> =
        buildSet {
            addAll(manualTags)
            addAll(entries.filterNot { it.isDeleted }.flatMap { it.payload.tags })
        }
            .filter { it.isNotBlank() }
            .sorted()

    fun addCategory(category: String): Boolean =
        addCategory(category, CategoryTemplate.defaultCategoryFields())

    fun addCategory(category: String, preset: CategoryTypePreset?, customFieldNames: List<String>): Boolean =
        addCategory(category, CategoryTemplate.fieldsForPreset(preset, customFieldNames))

    @Synchronized
    fun addCategory(category: String, fields: List<FieldTemplate>): Boolean {
        val normalized = category.trim()
        if (normalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        if (categories().any { it.equals(normalized, ignoreCase = true) }) {
            statusMessage = "Category already exists."
            return false
        }
        manualCategories += normalized
        categoryTemplates[normalized] = CategoryTemplate(
            category = normalized,
            fields = fields.ifEmpty { CategoryTemplate.defaultCategoryFields() },
        )
        persistUnlockedSnapshot()
        statusMessage = "Category added."
        return true
    }

    @Synchronized
    fun applyCategoryPreset(category: String, preset: CategoryTypePreset): Boolean {
        val normalized = category.trim()
        if (normalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        if (categories().none { it.equals(normalized, ignoreCase = true) }) {
            manualCategories += normalized
        }
        categoryTemplates[normalized] = CategoryTemplate(
            category = normalized,
            fields = CategoryTemplate.fieldsForPreset(preset),
        )
        persistUnlockedSnapshot()
        statusMessage = "Category template updated."
        return true
    }

    @Synchronized
    fun addTag(tag: String): Boolean =
        addTaxonomyValue(tag, manualTags, "Tag added.", "Tag already exists.")

    @Synchronized
    fun renameCategory(oldValue: String, newValue: String): Boolean {
        val oldNormalized = oldValue.trim()
        val newNormalized = newValue.trim()
        if (oldNormalized.isBlank() || newNormalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        if (categories().any { !it.equals(oldNormalized, ignoreCase = true) && it.equals(newNormalized, ignoreCase = true) }) {
            statusMessage = "Category already exists."
            return false
        }
        manualCategories.removeAll { it.equals(oldNormalized, ignoreCase = true) }
        manualCategories += newNormalized
        val oldTemplate = categoryTemplates.entries.firstOrNull { it.key.equals(oldNormalized, ignoreCase = true) }
        if (oldTemplate != null) {
            categoryTemplates.remove(oldTemplate.key)
            categoryTemplates[newNormalized] = oldTemplate.value.copy(category = newNormalized)
        }
        categoryTemplates.replaceAll { _, template ->
            val updatedFields = template.fields.map { field ->
                if (
                    field.valueType == "entryReference" &&
                    field.targetCategory.trim().equals(oldNormalized, ignoreCase = true)
                ) {
                    field.copy(targetCategory = newNormalized)
                } else {
                    field
                }
            }
            if (updatedFields == template.fields) template else template.copy(fields = updatedFields)
        }
        val now = Instant.now()
        entries.replaceAll { entry ->
            if (!entry.isDeleted && entry.payload.category.equals(oldNormalized, ignoreCase = true)) {
                entry.copy(payload = entry.payload.withCategory(newNormalized), updatedAt = now)
                    .markLocalEntryChange(syncSettings.deviceId, now)
            } else {
                entry
            }
        }
        persistUnlockedSnapshot()
        statusMessage = "Category updated."
        return true
    }

    @Synchronized
    fun deleteCategory(category: String): Boolean {
        val normalized = category.trim()
        if (normalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        var changed = manualCategories.removeAll { it.equals(normalized, ignoreCase = true) }
        val removedTemplate = categoryTemplates.entries.firstOrNull { it.key.equals(normalized, ignoreCase = true) }
        if (removedTemplate != null) {
            categoryTemplates.remove(removedTemplate.key)
            changed = true
        }
        val now = Instant.now()
        entries.replaceAll { entry ->
            if (!entry.isDeleted && entry.payload.category.equals(normalized, ignoreCase = true)) {
                changed = true
                entry.copy(payload = entry.payload.withCategory(""), updatedAt = now)
                    .markLocalEntryChange(syncSettings.deviceId, now)
            } else {
                entry
            }
        }
        if (!changed) {
            statusMessage = "Category not found."
            return false
        }
        persistUnlockedSnapshot()
        statusMessage = "Category deleted."
        return true
    }

    @Synchronized
    fun renameTag(oldValue: String, newValue: String): Boolean {
        val oldNormalized = oldValue.trim()
        val newNormalized = newValue.trim()
        if (oldNormalized.isBlank() || newNormalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        if (tags().any { !it.equals(oldNormalized, ignoreCase = true) && it.equals(newNormalized, ignoreCase = true) }) {
            statusMessage = "Tag already exists."
            return false
        }
        manualTags.removeAll { it.equals(oldNormalized, ignoreCase = true) }
        manualTags += newNormalized
        val now = Instant.now()
        entries.replaceAll { entry ->
            if (entry.isDeleted) {
                return@replaceAll entry
            }
            val updatedTags = entry.payload.tags.map { tag ->
                if (tag.equals(oldNormalized, ignoreCase = true)) newNormalized else tag
            }.distinct()
            if (updatedTags != entry.payload.tags) {
                entry.copy(payload = entry.payload.withTags(updatedTags), updatedAt = now)
                    .markLocalEntryChange(syncSettings.deviceId, now)
            } else {
                entry
            }
        }
        persistUnlockedSnapshot()
        statusMessage = "Tag updated."
        return true
    }

    @Synchronized
    fun deleteTag(tag: String): Boolean {
        val normalized = tag.trim()
        if (normalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        var changed = manualTags.removeAll { it.equals(normalized, ignoreCase = true) }
        val now = Instant.now()
        entries.replaceAll { entry ->
            if (entry.isDeleted) {
                return@replaceAll entry
            }
            val updatedTags = entry.payload.tags.filterNot { it.equals(normalized, ignoreCase = true) }
            if (updatedTags.size != entry.payload.tags.size) {
                changed = true
                entry.copy(payload = entry.payload.withTags(updatedTags), updatedAt = now)
                    .markLocalEntryChange(syncSettings.deviceId, now)
            } else {
                entry
            }
        }
        if (!changed) {
            statusMessage = "Tag not found."
            return false
        }
        persistUnlockedSnapshot()
        statusMessage = "Tag deleted."
        return true
    }

    fun syncNow() {
        if (!beginSyncIfPossible()) {
            return
        }
        val client = syncClientFactory.makeClient(syncSettings)
        if (client == null) {
            isSyncing = false
            syncStatus = "Not configured"
            statusMessage = "Configure a sync provider before syncing."
            persistUnlockedSnapshot(markLocalChange = false)
            return
        }
        performSyncLoop(client)
    }

    fun syncNow(client: RemoteSyncClient) {
        if (!beginSyncIfPossible()) {
            return
        }
        performSyncLoop(client)
    }

    private fun performSyncLoop(client: RemoteSyncClient) {
        try {
            do {
                syncRequestedAgain = false
                val revisionAtStart = localChangeRevision
                runCatching {
                    val syncInput = synchronized(this) {
                        saveSnapshot()
                        syncStatus = "Syncing..."
                        statusMessage = "Sync started."
                        val key = activeVaultKey?.copyOf()
                            ?: throw IllegalStateException("Vault encryption key is missing.")
                        SyncLoopInput(
                            snapshot = currentSnapshot(),
                            settings = syncSettings,
                            vaultKey = key,
                            masterKeyRecord = masterKeyRecord,
                            masterPassword = this@VaultStore.masterPassword,
                        )
                    }
                    val encryptedClient = EncryptedRemoteSyncClient(
                        delegate = client,
                        crypto = crypto,
                        vaultKey = syncInput.vaultKey,
                        masterKeyRecord = syncInput.masterKeyRecord,
                        masterPassword = syncInput.masterPassword,
                        includeMasterKeyRecord = syncInput.settings.syncMasterKey,
                    )
                    val result = syncEngine.synchronize(
                        localSnapshot = syncInput.snapshot,
                        settings = syncInput.settings,
                        client = encryptedClient,
                        shouldCancelUpload = { localChangeRevision != revisionAtStart },
                    )
                    if (encryptedClient.downloadedPlaintextRemote && !result.uploaded) {
                        if (localChangeRevision != revisionAtStart) {
                            throw VaultSyncCancelledException()
                        }
                        val migration = encryptedClient.upload(
                            syncEngine.encodePayload(
                                VaultSyncPayload(
                                    exportedAt = Instant.now(),
                                    deviceId = syncInput.settings.deviceId,
                                    revision = result.settings.lastSyncRevision,
                                    snapshot = result.snapshot,
                                )
                            )
                        )
                        if (migration.statusCode !in 200..299) {
                            throw VaultSyncEngineException("Sync upload failed with status ${migration.statusCode}.")
                        }
                    }
                    synchronized(this) {
                        if (localChangeRevision != revisionAtStart) {
                            syncRequestedAgain = true
                        } else {
                            encryptedClient.remoteMasterKeyRecord?.let { remoteRecord ->
                                val remoteKey = checkNotNull(encryptedClient.resolvedRemoteVaultKey())
                                masterKeyRecord = remoteRecord
                                activeVaultKey = remoteKey
                                hasMasterKey = true
                            }
                            applySyncResult(result)
                        }
                    }
                }.onFailure {
                    if (it is VaultSyncCancelledException) {
                        syncRequestedAgain = true
                    } else {
                        recordSyncFailure(it)
                    }
                }
            } while (syncRequestedAgain)
        } finally {
            isSyncing = false
        }
    }

    @Synchronized
    private fun beginSyncIfPossible(): Boolean {
        if (isSyncing) {
            syncRequestedAgain = true
            return false
        }
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before syncing."
            return false
        }
        isSyncing = true
        return true
    }

    @Synchronized
    fun updateSyncSettings(settings: SyncSettings) {
        runCatching {
            val updated = settings.copy(hasLocalChanges = syncSettings.hasLocalChanges)
            val saved = syncSettingsRepository?.save(updated) ?: updated
            syncSettings = saved
            syncStatus = if (saved.providerType == SyncProviderType.NONE) {
                "Not configured"
            } else {
                "Configured: ${saved.providerType.title}"
            }
            persistUnlockedSnapshot(markLocalChange = false)
            statusMessage = "Sync settings saved."
        }.onFailure {
            statusMessage = it.message
        }
    }

    @Synchronized
    fun runBackup() {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before running backup."
            return
        }
        runCatching {
            saveSnapshot()
            val backupFile = repository.createBackup()
            backupStatus = "Backup saved: ${backupFile.name}"
            saveSnapshot()
            statusMessage = backupStatus
        }.onFailure {
            statusMessage = it.message
        }
    }

    fun listBackups(): List<BackupInfo> =
        runCatching {
            repository.listBackups().map { file ->
                BackupInfo(
                    fileName = file.name,
                    sizeBytes = file.length(),
                    modifiedAt = Instant.ofEpochMilli(file.lastModified()),
                )
            }
        }.getOrElse {
            statusMessage = it.message
            emptyList()
        }

    @Synchronized
    fun restoreLatestBackup() {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before restoring backup."
            return
        }
        val key = activeVaultKey ?: run {
            statusMessage = "Unlock the vault before restoring backup."
            return
        }
        runCatching {
            val backupFile = repository.restoreLatestBackup()
            loadEnvelopeMetadata()
            loadSnapshot(key)
            backupStatus = "Restored backup: ${backupFile.name}"
            markLocalChangesForSync()
            saveSnapshot()
            statusMessage = backupStatus
        }.onFailure {
            statusMessage = it.message
        }
    }

    @Synchronized
    fun restoreBackup(fileName: String) {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before restoring backup."
            return
        }
        val key = activeVaultKey ?: run {
            statusMessage = "Unlock the vault before restoring backup."
            return
        }
        runCatching {
            val backupFile = repository.restoreBackup(fileName)
            loadEnvelopeMetadata()
            loadSnapshot(key)
            backupStatus = "Restored backup: ${backupFile.name}"
            markLocalChangesForSync()
            saveSnapshot()
            statusMessage = backupStatus
        }.onFailure {
            statusMessage = it.message
        }
    }

    fun exportSnapshot() {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before exporting."
            return
        }
        runCatching {
            saveSnapshot()
            val exportFile = repository.saveSnapshotExport(currentSnapshot())
            statusMessage = "Export saved: ${exportFile.name}"
        }.onFailure {
            statusMessage = it.message
        }
    }

    fun exportSnapshotJson(): String? {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before exporting."
            return null
        }
        return runCatching {
            saveSnapshot()
            statusMessage = "Full vault export is ready."
            VaultJson.encodeSnapshot(currentSnapshot())
        }.getOrElse {
            statusMessage = it.message
            null
        }
    }

    fun exportEntry(entry: VaultEntry) {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before exporting."
            return
        }
        runCatching {
            val exportFile = repository.saveEntryExport(
                entry = entry,
                categoryTemplates = categoryTemplate(entry.payload.category)?.let(::listOf).orEmpty(),
            )
            statusMessage = "Entry export saved: ${exportFile.name}"
        }.onFailure {
            statusMessage = it.message
        }
    }

    fun exportEntryJson(entry: VaultEntry, selectedFieldIds: Set<String>? = null): String? {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before exporting."
            return null
        }
        return runCatching {
            statusMessage = "Entry export is ready."
            val exportedEntry = selectedFieldIds?.let { entry.keepingExportFields(it) } ?: entry
            VaultJson.encodeScopedExport(
                ScopedVaultExport(
                    scope = ScopedExportScope.ITEM,
                    exportedAt = Instant.now(),
                    item = exportedEntry,
                    category = null,
                    items = null,
                    categoryTemplates = categoryTemplate(entry.payload.category)?.let(::listOf).orEmpty(),
                )
            )
        }.getOrElse {
            statusMessage = it.message
            null
        }
    }

    fun exportCategory(category: String) {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before exporting."
            return
        }
        runCatching {
            val exportedEntries = entries
                .filter { !it.isDeleted && it.payload.category == category }
                .sortedBy { it.label }
            val exportFile = repository.saveCategoryExport(
                category = category,
                entries = exportedEntries,
                categoryTemplates = categoryTemplate(category)?.let(::listOf).orEmpty(),
            )
            statusMessage = "Category export saved: ${exportFile.name}"
        }.onFailure {
            statusMessage = it.message
        }
    }

    fun exportCategoryJson(category: String): String? {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before exporting."
            return null
        }
        return runCatching {
            val exportedEntries = entries
                .filter { !it.isDeleted && it.payload.category == category }
                .sortedBy { it.label }
            statusMessage = "Category export is ready."
            VaultJson.encodeScopedExport(
                ScopedVaultExport(
                    scope = ScopedExportScope.CATEGORY,
                    exportedAt = Instant.now(),
                    item = null,
                    category = category,
                    items = exportedEntries,
                    categoryTemplates = categoryTemplate(category)?.let(::listOf).orEmpty(),
                )
            )
        }.getOrElse {
            statusMessage = it.message
            null
        }
    }

    @Synchronized
    fun importSnapshot(fileName: String) {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before importing."
            return
        }
        runCatching {
            val snapshot = repository.loadSnapshotImport(fileName)
            applySnapshotState(snapshot)
            markLocalChangesForSync()
            saveSnapshot()
            statusMessage = "Imported ${entries.count { !it.isDeleted }} active entries."
        }.onFailure {
            statusMessage = it.message
        }
    }

    @Synchronized
    fun importSnapshotJson(raw: String): Boolean {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before importing."
            return false
        }
        return runCatching {
            val snapshot = VaultJson.decodeImportSnapshot(raw, masterPassword, crypto)
            applySnapshotState(snapshot)
            markLocalChangesForSync()
            saveSnapshot()
            statusMessage = "Imported ${entries.count { !it.isDeleted }} active entries."
            true
        }.onFailure {
            statusMessage = it.message
        }.getOrDefault(false)
    }

    @Synchronized
    fun importScopedExport(fileName: String, strategy: ImportConflictStrategy) {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before importing."
            return
        }
        runCatching {
            val scopedExport = repository.loadScopedImport(fileName)
            val importedEntries = when (scopedExport.scope) {
                ScopedExportScope.ITEM -> scopedExport.item?.let { listOf(it) }.orEmpty()
                ScopedExportScope.CATEGORY -> scopedExport.items.orEmpty()
            }
            val templatesChanged = mergeImportedCategoryTemplates(scopedExport.categoryTemplates)
            val result = applyImportedEntries(importedEntries, strategy)
            persistUnlockedSnapshot(
                markLocalChange = templatesChanged || result.created > 0 || result.updated > 0,
            )
            statusMessage = "Imported ${result.created} created, ${result.updated} updated, ${result.skipped} skipped."
        }.onFailure {
            statusMessage = it.message
        }
    }

    @Synchronized
    fun importScopedExportJson(raw: String, strategy: ImportConflictStrategy): Boolean {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before importing."
            return false
        }
        return runCatching {
            val scopedExport = VaultJson.decodeScopedExport(raw)
            val importedEntries = when (scopedExport.scope) {
                ScopedExportScope.ITEM -> scopedExport.item?.let { listOf(it) }.orEmpty()
                ScopedExportScope.CATEGORY -> scopedExport.items.orEmpty()
            }
            val templatesChanged = mergeImportedCategoryTemplates(scopedExport.categoryTemplates)
            val result = applyImportedEntries(importedEntries, strategy)
            persistUnlockedSnapshot(
                markLocalChange = templatesChanged || result.created > 0 || result.updated > 0,
            )
            statusMessage = "Imported ${result.created} created, ${result.updated} updated, ${result.skipped} skipped."
            true
        }.onFailure {
            statusMessage = it.message
        }.getOrDefault(false)
    }

    @Synchronized
    fun setRequireTotp(required: Boolean) {
        requireTotp = required
        persistUnlockedSnapshot()
    }

    @Synchronized
    fun setTotpSecret(secret: String) {
        totpSecret = secret.trim()
        persistUnlockedSnapshot()
    }

    @Synchronized
    fun clearAllData(password: String): Boolean {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before clearing data."
            return false
        }
        if (!verifyMasterPassword(password)) {
            return false
        }
        entries.clear()
        manualCategories.clear()
        categoryTemplates.clear()
        manualTags.clear()
        requireTotp = false
        totpSecret = ""
        backupStatus = "No backup has run"
        markLocalChangesForSync()
        saveSnapshot()
        statusMessage = "Vault data cleared."
        return true
    }

    private fun loadEnvelopeMetadata() {
        runCatching {
            val envelope = repository.loadEnvelope()
            masterKeyRecord = envelope?.masterKeyRecord
            hasMasterKey = masterKeyRecord != null
            statusMessage = if (hasMasterKey) "Encrypted vault found." else null
        }.onFailure {
            statusMessage = it.message
        }
    }

    private fun loadSyncSettings() {
        runCatching {
            syncSettingsRepository?.load()?.let { loaded ->
                syncSettings = loaded
                syncStatus = if (loaded.providerType == SyncProviderType.NONE) {
                    "Not configured"
                } else {
                    "Configured: ${loaded.providerType.title}"
                }
            }
        }.onFailure {
            statusMessage = it.message
        }
    }

    private fun loadSnapshot(key: ByteArray) {
        val envelope = repository.loadEnvelope()
        val encryptedVault = envelope?.encryptedVault
        if (encryptedVault == null) {
            applySnapshotState(VaultSnapshot())
            return
        }
        val snapshot = repository.decodeSnapshot(crypto.decrypt(encryptedVault, key))
        applySnapshotState(snapshot)
    }

    private fun saveSnapshot() {
        val record = masterKeyRecord ?: return
        val key = activeVaultKey ?: return
        val encrypted = crypto.encrypt(repository.encodeSnapshot(currentSnapshot()), key)
        repository.saveEnvelope(
            VaultPersistenceEnvelope(
                schemaVersion = 1,
                masterKeyRecord = record,
                encryptedVault = encrypted,
                updatedAt = Instant.now(),
            )
        )
    }

    private fun currentSnapshot(): VaultSnapshot =
        VaultSnapshot(
            entries = entries.toList(),
            categories = categories(),
            categoryTemplates = categoryTemplates.values
                .filter { it.category.isNotBlank() }
                .sortedBy { it.category.lowercase() },
            tags = tags(),
            security = SecuritySettings(requireTotp = requireTotp, totpSecret = totpSecret),
            syncStatus = syncStatus,
            backupStatus = backupStatus,
            updatedAt = Instant.now(),
        )

    private fun applySyncResult(result: VaultSyncEngineResult) {
        applySnapshotState(result.snapshot)
        syncSettings = result.settings.copy(hasLocalChanges = false)
        syncStatus = result.settings.lastSyncMessage ?: "Sync complete."
        statusMessage = syncStatus
        syncSettingsRepository?.save(syncSettings)
        saveSnapshot()
    }

    private fun recordSyncFailure(error: Throwable) {
        val message = error.message ?: "Sync failed."
        val failedSettings = syncSettings.copy(
            lastSyncAt = Instant.now(),
            lastSyncStatus = "error",
            lastSyncMessage = message,
            logs = (listOf(
                SyncLogEntry(
                    timestamp = Instant.now(),
                    message = message,
                    level = "error",
                )
            ) + syncSettings.logs).take(50),
        )
        syncSettings = failedSettings
        syncStatus = "Sync failed"
        statusMessage = message
        runCatching { syncSettingsRepository?.save(failedSettings) }
        persistUnlockedSnapshot(markLocalChange = false)
    }

    private fun applyImportedEntries(
        importedEntries: List<VaultEntry>,
        strategy: ImportConflictStrategy,
    ): ImportResult {
        var created = 0
        var updated = 0
        var skipped = 0
        importedEntries.filter { !it.isDeleted }.forEach { imported ->
            val existingIndex = entries.indexOfFirst {
                !it.isDeleted && it.importMatchKey == imported.importMatchKey
            }
            if (existingIndex >= 0) {
                when (strategy) {
                    ImportConflictStrategy.SKIP -> skipped += 1
                    ImportConflictStrategy.OVERWRITE -> {
                        entries[existingIndex] = imported.copyForImport(
                            id = entries[existingIndex].id,
                            updatedAt = Instant.now(),
                        )
                        updated += 1
                    }
                    ImportConflictStrategy.KEEP_COPY -> {
                        entries += imported.copyForImport(updatedAt = Instant.now())
                        created += 1
                    }
                }
            } else {
                entries += imported.copyForImport(updatedAt = Instant.now())
                created += 1
            }
        }
        return ImportResult(created = created, updated = updated, skipped = skipped)
    }

    private fun mergeImportedCategoryTemplates(importedTemplates: List<CategoryTemplate>): Boolean {
        var changed = false
        importedTemplates.forEach { importedTemplate ->
            val importedCategory = importedTemplate.category.trim()
            if (importedCategory.isBlank()) return@forEach

            if (manualCategories.none { it.equals(importedCategory, ignoreCase = true) }) {
                manualCategories += importedCategory
                changed = true
            }

            val existingEntry = categoryTemplates.entries.firstOrNull {
                it.key.equals(importedCategory, ignoreCase = true)
            }
            if (existingEntry == null) {
                categoryTemplates[importedCategory] = importedTemplate.copy(category = importedCategory)
                changed = true
                return@forEach
            }

            val mergedFields = existingEntry.value.fields.toMutableList()
            importedTemplate.fields.forEach { importedField ->
                val existingIndex = mergedFields.indexOfFirst { it.id == importedField.id }
                if (existingIndex < 0) {
                    mergedFields += importedField
                    changed = true
                } else if (mergedFields[existingIndex] != importedField) {
                    mergedFields[existingIndex] = importedField
                    changed = true
                }
            }
            if (existingEntry.value.category != importedCategory || existingEntry.value.fields != mergedFields) {
                categoryTemplates.remove(existingEntry.key)
                categoryTemplates[importedCategory] = CategoryTemplate(importedCategory, mergedFields)
                changed = true
            }
        }
        return changed
    }

    private fun applySnapshotState(snapshot: VaultSnapshot) {
        entries.clear()
        entries += snapshot.entries
        manualCategories.clear()
        manualCategories += snapshot.categories.map { it.trim() }.filter { it.isNotBlank() }
        categoryTemplates.clear()
        snapshot.categoryTemplates.forEach { template ->
            val normalized = template.category.trim()
            if (normalized.isNotBlank()) {
                categoryTemplates[normalized] = template.copy(category = normalized)
            }
        }
        manualCategories.forEach { category ->
            categoryTemplates.putIfAbsent(category, CategoryTemplate(category = category))
        }
        manualTags.clear()
        manualTags += snapshot.tags.map { it.trim() }.filter { it.isNotBlank() }
        requireTotp = snapshot.security.requireTotp
        totpSecret = snapshot.security.totpSecret
        syncStatus = snapshot.syncStatus
        backupStatus = snapshot.backupStatus
    }

    private fun addTaxonomyValue(
        value: String,
        target: MutableSet<String>,
        successMessage: String,
        duplicateMessage: String,
    ): Boolean {
        val normalized = value.trim()
        if (normalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        val existed = target.any { it.equals(normalized, ignoreCase = true) }
        if (!existed) {
            target += normalized
            persistUnlockedSnapshot()
            statusMessage = successMessage
            return true
        }
        statusMessage = duplicateMessage
        return false
    }

    private fun persistUnlockedSnapshot(markLocalChange: Boolean = true) {
        if (!isUnlocked) return
        runCatching {
            if (markLocalChange) {
                markLocalChangesForSync()
            }
            saveSnapshot()
            statusMessage = "Vault saved"
        }.onFailure {
            statusMessage = it.message
        }
    }

    @Synchronized
    private fun markLocalChangesForSync() {
        localChangeRevision += 1
        if (isSyncing) {
            syncRequestedAgain = true
        }
        if (syncSettings.hasLocalChanges) {
            return
        }
        syncSettings = syncSettings.copy(hasLocalChanges = true)
        syncSettingsRepository?.save(syncSettings)
    }
}

fun List<CustomField>.withTemplateDefaults(template: CategoryTemplate?): List<CustomField> {
    if (template == null) return this
    val existingNames = map { it.name.trim().lowercase() }.toMutableSet()
    val additions = template.fields
        .filter { field -> field.valueType == "text" }
        .filter { field -> field.name.trim().isNotEmpty() }
        .filter { field -> existingNames.add(field.name.trim().lowercase()) }
        .map { field ->
            CustomField(
                templateFieldId = field.id,
                name = field.name.trim(),
            )
        }
    return this + additions
}

private data class ImportResult(
    val created: Int,
    val updated: Int,
    val skipped: Int,
)

private fun VaultPayload.withCategory(category: String): VaultPayload =
    when (this) {
        is VaultPayload.Credential -> copy(value = value.copy(category = category))
        is VaultPayload.Server -> copy(value = value.copy(category = category))
        is VaultPayload.Service -> copy(value = value.copy(category = category))
    }

private fun VaultPayload.withTags(tags: List<String>): VaultPayload =
    when (this) {
        is VaultPayload.Credential -> copy(value = value.copy(tags = tags))
        is VaultPayload.Server -> copy(value = value.copy(tags = tags))
        is VaultPayload.Service -> copy(value = value.copy(tags = tags))
    }

private fun VaultEntry.markLocalEntryChange(deviceId: String, updatedAt: Instant): VaultEntry {
    val updater = deviceId.ifBlank { updatedBy.ifBlank { "android" } }
    val nextVersion = version.toMutableMap()
    nextVersion[updater] = (nextVersion[updater] ?: 0) + 1
    return copy(
        updatedAt = updatedAt,
        updatedBy = updater,
        version = nextVersion,
    )
}

private fun VaultEntry.keepingExportFields(selectedFieldIds: Set<String>): VaultEntry =
    copy(
        label = if ("label" in selectedFieldIds) label else "",
        payload = payload.keepingExportFields(selectedFieldIds),
        customFields = customFields.filter { "custom.${it.id}" in selectedFieldIds },
    )

private fun VaultPayload.keepingExportFields(selectedFieldIds: Set<String>): VaultPayload =
    when (this) {
        is VaultPayload.Credential -> copy(
            value = value.copy(
                username = if ("credential.username" in selectedFieldIds) value.username else "",
                password = if ("credential.password" in selectedFieldIds) value.password else "",
                accounts = if ("credential.accounts" in selectedFieldIds) value.accounts else emptyList(),
                token = if ("credential.token" in selectedFieldIds) value.token else "",
                appId = if ("credential.appId" in selectedFieldIds) value.appId else "",
                accessKey = if ("credential.accessKey" in selectedFieldIds) value.accessKey else "",
                secretKey = if ("credential.secretKey" in selectedFieldIds) value.secretKey else "",
                notes = if ("credential.notes" in selectedFieldIds) value.notes else "",
                tags = if ("tags" in selectedFieldIds) value.tags else emptyList(),
                category = if ("category" in selectedFieldIds) value.category else "",
            )
        )
        is VaultPayload.Server -> copy(
            value = value.copy(
                name = if ("server.name" in selectedFieldIds) value.name else "",
                ipAddress = if ("server.ipAddress" in selectedFieldIds) value.ipAddress else "",
                port = if ("server.port" in selectedFieldIds) value.port else "",
                username = if ("server.username" in selectedFieldIds) value.username else "",
                password = if ("server.password" in selectedFieldIds) value.password else "",
                accounts = if ("server.accounts" in selectedFieldIds) value.accounts else emptyList(),
                basicConfig = if ("server.basicConfig" in selectedFieldIds) value.basicConfig else "",
                operatingSystem = if ("server.operatingSystem" in selectedFieldIds) value.operatingSystem else "",
                location = if ("server.location" in selectedFieldIds) value.location else "",
                notes = if ("server.notes" in selectedFieldIds) value.notes else "",
                tags = if ("tags" in selectedFieldIds) value.tags else emptyList(),
                category = if ("category" in selectedFieldIds) value.category else "",
            )
        )
        is VaultPayload.Service -> copy(
            value = value.copy(
                name = if ("service.name" in selectedFieldIds) value.name else "",
                connectionAddress = if ("service.connectionAddress" in selectedFieldIds) value.connectionAddress else "",
                connectionPort = if ("service.connectionPort" in selectedFieldIds) value.connectionPort else "",
                accountId = if ("service.accountId" in selectedFieldIds) value.accountId else null,
                serverIds = if ("service.serverIds" in selectedFieldIds) value.serverIds else emptyList(),
                accounts = if ("service.accounts" in selectedFieldIds) value.accounts else emptyList(),
                notes = if ("service.notes" in selectedFieldIds) value.notes else "",
                tags = if ("tags" in selectedFieldIds) value.tags else emptyList(),
                category = if ("category" in selectedFieldIds) value.category else "",
            )
        )
    }
