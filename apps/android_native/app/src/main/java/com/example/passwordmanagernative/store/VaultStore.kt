package com.example.passwordmanagernative.store

import android.content.Context
import com.example.passwordmanagernative.model.EntryDraft
import com.example.passwordmanagernative.model.ImportConflictStrategy
import com.example.passwordmanagernative.model.MasterKeyRecord
import com.example.passwordmanagernative.model.ScopedExportScope
import com.example.passwordmanagernative.model.ScopedVaultExport
import com.example.passwordmanagernative.model.SecuritySettings
import com.example.passwordmanagernative.model.VaultEntry
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultPayload
import com.example.passwordmanagernative.model.VaultPersistenceEnvelope
import com.example.passwordmanagernative.model.VaultSnapshot
import com.example.passwordmanagernative.model.copyForImport
import com.example.passwordmanagernative.model.importMatchKey
import com.example.passwordmanagernative.sync.RemoteSyncClient
import com.example.passwordmanagernative.sync.SyncClientFactory
import com.example.passwordmanagernative.sync.SyncLogEntry
import com.example.passwordmanagernative.sync.SyncProviderType
import com.example.passwordmanagernative.sync.SyncSettings
import com.example.passwordmanagernative.sync.SyncSettingsRepository
import com.example.passwordmanagernative.sync.VaultSyncEngine
import com.example.passwordmanagernative.sync.VaultSyncEngineResult
import java.time.Instant

data class BackupInfo(
    val fileName: String,
    val sizeBytes: Long,
    val modifiedAt: Instant,
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
    private val manualTags = mutableSetOf<String>()

    init {
        loadSyncSettings()
        loadEnvelopeMetadata()
        if (ensureKeystoreWrappingKey) {
            runCatching { crypto.ensureKeystoreWrappingKey() }
                .onFailure { statusMessage = "Android Keystore is unavailable: ${it.message}" }
        }
    }

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
        val normalizedQuery = query.trim().lowercase()
        return entries
            .asSequence()
            .filter { !it.isDeleted }
            .filter { type == null || it.type == type }
            .filter { category == null || it.payload.category == category }
            .filter { tag == null || it.payload.tags.contains(tag) }
            .filter {
                normalizedQuery.isEmpty() ||
                    buildString {
                        append(it.label)
                        append(' ')
                        append(it.type.name)
                        append(' ')
                        append(it.payload.category)
                        append(' ')
                        append(it.payload.tags.joinToString(" "))
                    }.lowercase().contains(normalizedQuery)
            }
            .sortedByDescending { it.updatedAt }
            .toList()
    }

    fun upsert(draft: EntryDraft, editingId: String? = null): VaultEntry {
        val now = Instant.now()
        val normalizedTags = draft.tags.map { it.trim() }.filter { it.isNotEmpty() }
        val normalizedDraft = draft.copy(
            category = draft.category.trim(),
            tags = normalizedTags,
            customFields = draft.customFields
                .map { it.copy(name = it.name.trim(), value = it.value.trim()) }
                .filter { it.name.isNotBlank() || it.value.isNotBlank() },
        )
        val existingIndex = editingId?.let { id -> entries.indexOfFirst { it.id == id } } ?: -1
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
            addAll(entries.filterNot { it.isDeleted }.map { it.payload.category })
        }
            .filter { it.isNotBlank() }
            .sorted()

    fun tags(): List<String> =
        buildSet {
            addAll(manualTags)
            addAll(entries.filterNot { it.isDeleted }.flatMap { it.payload.tags })
        }
            .filter { it.isNotBlank() }
            .sorted()

    fun addCategory(category: String): Boolean =
        addTaxonomyValue(category, manualCategories, "Category added.", "Category already exists.")

    fun addTag(tag: String): Boolean =
        addTaxonomyValue(tag, manualTags, "Tag added.", "Tag already exists.")

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

    fun deleteCategory(category: String): Boolean {
        val normalized = category.trim()
        if (normalized.isBlank()) {
            statusMessage = "Value is required."
            return false
        }
        var changed = manualCategories.removeAll { it.equals(normalized, ignoreCase = true) }
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
        val client = syncClientFactory.makeClient(syncSettings)
        if (client == null) {
            syncStatus = "Not configured"
            statusMessage = "Configure a sync provider before syncing."
            persistUnlockedSnapshot(markLocalChange = false)
            return
        }
        syncNow(client)
    }

    fun syncNow(client: RemoteSyncClient) {
        if (!isUnlocked) {
            statusMessage = "Unlock the vault before syncing."
            return
        }
        runCatching {
            saveSnapshot()
            syncStatus = "Syncing..."
            statusMessage = "Sync started."
            val result = syncEngine.synchronize(
                localSnapshot = currentSnapshot(),
                settings = syncSettings,
                client = client,
            )
            applySyncResult(result)
        }.onFailure {
            recordSyncFailure(it)
        }
    }

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
            val exportFile = repository.saveEntryExport(entry)
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
            val exportFile = repository.saveCategoryExport(category, exportedEntries)
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
                )
            )
        }.getOrElse {
            statusMessage = it.message
            null
        }
    }

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
            val result = applyImportedEntries(importedEntries, strategy)
            persistUnlockedSnapshot(markLocalChange = result.created > 0 || result.updated > 0)
            statusMessage = "Imported ${result.created} created, ${result.updated} updated, ${result.skipped} skipped."
        }.onFailure {
            statusMessage = it.message
        }
    }

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
            val result = applyImportedEntries(importedEntries, strategy)
            persistUnlockedSnapshot(markLocalChange = result.created > 0 || result.updated > 0)
            statusMessage = "Imported ${result.created} created, ${result.updated} updated, ${result.skipped} skipped."
            true
        }.onFailure {
            statusMessage = it.message
        }.getOrDefault(false)
    }

    fun setRequireTotp(required: Boolean) {
        requireTotp = required
        persistUnlockedSnapshot()
    }

    fun setTotpSecret(secret: String) {
        totpSecret = secret.trim()
        persistUnlockedSnapshot()
    }

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

    private fun applySnapshotState(snapshot: VaultSnapshot) {
        entries.clear()
        entries += snapshot.entries
        manualCategories.clear()
        manualCategories += snapshot.categories.map { it.trim() }.filter { it.isNotBlank() }
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

    private fun markLocalChangesForSync() {
        if (syncSettings.hasLocalChanges) {
            return
        }
        syncSettings = syncSettings.copy(hasLocalChanges = true)
        syncSettingsRepository?.save(syncSettings)
    }
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
    val updater = deviceId.ifBlank { updatedBy.ifBlank { "android-native" } }
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
