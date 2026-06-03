import Foundation
import Observation

private struct PreparedUnlockResult: Sendable {
    var key: Data
    var snapshot: VaultSnapshot?
}

@Observable
@MainActor
final class VaultStore {
    private(set) var isUnlocked = false
    private(set) var hasMasterKey = false
    private(set) var entries: [VaultEntry] = []
    private(set) var categories: [String] = []
    private(set) var tags: [String] = []
    private(set) var syncStatus = "Not configured"
    private(set) var lastBackupStatus = "No backup has run"
    private(set) var statusMessage: String?
    private(set) var requireTotp = false
    private(set) var totpSecret = ""
    private(set) var syncSettings = SyncSettings.defaults()

    private var manualCategories: Set<String> = []
    private var manualTags: Set<String> = []
    private var masterPassword = ""
    private var masterKeyRecord: MasterKeyRecord?
    private var activeVaultKey: Data?
    private let repository: FileVaultRepository
    private let syncSettingsRepository: SyncSettingsRepository?
    private let syncClientFactory: SyncClientFactory
    private let syncEngine: VaultSyncEngine
    private let crypto: VaultCryptoService
    private let totp: TotpService

    init(
        repository: FileVaultRepository = FileVaultRepository(),
        syncSettingsRepository: SyncSettingsRepository? = try? SyncSettingsRepository(),
        syncClientFactory: SyncClientFactory = SyncClientFactory(),
        syncEngine: VaultSyncEngine = VaultSyncEngine(),
        crypto: VaultCryptoService = VaultCryptoService(),
        totp: TotpService = TotpService()
    ) {
        self.repository = repository
        self.syncSettingsRepository = syncSettingsRepository
        self.syncClientFactory = syncClientFactory
        self.syncEngine = syncEngine
        self.crypto = crypto
        self.totp = totp
        loadSyncSettings()
        loadEnvelopeMetadata()
    }

    func setupMasterPassword(_ password: String, confirmation: String) -> Bool {
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password == confirmation else {
            statusMessage = "Master password is empty or confirmation does not match."
            return false
        }
        do {
            let record = try crypto.makeMasterKeyRecord(password: password)
            let key = try crypto.verify(password: password, record: record)
            masterPassword = password
            masterKeyRecord = record
            activeVaultKey = key
            hasMasterKey = true
            isUnlocked = true
            seedInitialCollectionsIfNeeded()
            try markLocalChangesForSync()
            try saveSnapshot()
            statusMessage = "Vault initialized and encrypted locally."
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func unlock(password: String, totpCode: String = "") -> Bool {
        guard let record = masterKeyRecord else {
            statusMessage = "No vault has been initialized."
            return false
        }
        if requireTotp {
            guard !totpSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusMessage = "2FA secret is not configured."
                return false
            }
            guard totp.verifyCode(secret: totpSecret, code: totpCode) else {
                statusMessage = "2FA code is invalid."
                return false
            }
        }
        do {
            let key = try crypto.verify(password: password, record: record)
            try loadSnapshot(key: key)
            masterPassword = password
            activeVaultKey = key
            isUnlocked = true
            statusMessage = "Vault unlocked."
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func prepareBiometricUnlock(password: String, totpCode: String = "") async -> Bool {
        guard let record = masterKeyRecord else {
            statusMessage = "No vault has been initialized."
            return false
        }
        if requireTotp {
            guard !totpSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusMessage = "2FA secret is not configured."
                return false
            }
            guard totp.verifyCode(secret: totpSecret, code: totpCode) else {
                statusMessage = "2FA code is invalid."
                return false
            }
        }

        do {
            let vaultURL = try repository.vaultURL
            let result = try await Self.loadUnlockResult(
                password: password,
                record: record,
                vaultURL: vaultURL,
                crypto: crypto
            )
            applyUnlockResult(result, password: password)
            statusMessage = "Vault unlocked."
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func verifyMasterPassword(_ password: String) -> Bool {
        guard let record = masterKeyRecord else {
            statusMessage = "No vault has been initialized."
            return false
        }
        do {
            _ = try crypto.verify(password: password, record: record)
            return true
        } catch {
            statusMessage = "Vault authentication failed."
            return false
        }
    }

    func lock() {
        isUnlocked = false
        masterPassword = ""
        activeVaultKey = nil
    }

    func upsert(_ draft: EntryDraft, editing entry: VaultEntry?) {
        let now = Date()
        let payload = draft.payload
        let normalizedTags = draft.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedCategory = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPayload = payload.replacingCategory(normalizedCategory, tags: normalizedTags)

        if let entry, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].label = draft.label
            entries[index].type = finalPayload.storageKind
            entries[index].payload = finalPayload
            entries[index].customFields = draft.normalizedCustomFields
            entries[index].updatedAt = now
            entries[index].isDeleted = false
            entries[index].deletedAt = nil
            entries[index].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
        } else {
            var newEntry = VaultEntry(
                label: draft.label,
                type: finalPayload.storageKind,
                payload: finalPayload,
                customFields: draft.normalizedCustomFields,
                createdAt: now,
                updatedAt: now
            )
            newEntry.markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
            entries.append(newEntry)
        }
        rebuildCollections()
        persistUnlockedSnapshot()
    }

    func delete(_ entry: VaultEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let now = Date()
        entries[index].isDeleted = true
        entries[index].deletedAt = now
        entries[index].updatedAt = now
        entries[index].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
        rebuildCollections()
        persistUnlockedSnapshot()
    }

    func addCategory(_ category: String) -> Bool {
        guard let normalized = validatedTaxonomyValue(
            category,
            existingValues: categories,
            duplicateMessage: "Category already exists."
        ) else {
            return false
        }
        manualCategories.insert(normalized)
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Category added."
        return true
    }

    func addTag(_ tag: String) -> Bool {
        guard let normalized = validatedTaxonomyValue(
            tag,
            existingValues: tags,
            duplicateMessage: "Tag already exists."
        ) else {
            return false
        }
        manualTags.insert(normalized)
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Tag added."
        return true
    }

    func renameCategory(_ oldValue: String, to newValue: String) -> Bool {
        let oldNormalized = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNormalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldNormalized.isEmpty, !newNormalized.isEmpty else {
            statusMessage = "Value is required."
            return false
        }
        guard !categories.contains(where: {
            !$0.caseInsensitiveEquals(oldNormalized) && $0.caseInsensitiveEquals(newNormalized)
        }) else {
            statusMessage = "Category already exists."
            return false
        }

        removeTaxonomyValue(oldNormalized, from: &manualCategories)
        manualCategories.insert(newNormalized)
        for index in entries.indices where entries[index].payload.category.caseInsensitiveEquals(oldNormalized) {
            let now = Date()
            entries[index].payload = entries[index].payload.replacingCategory(
                newNormalized,
                tags: entries[index].payload.tags
            )
            entries[index].updatedAt = now
            entries[index].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
        }
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Category updated."
        return true
    }

    func deleteCategory(_ category: String) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Value is required."
            return false
        }

        var changed = removeTaxonomyValue(normalized, from: &manualCategories)
        for index in entries.indices where entries[index].payload.category.caseInsensitiveEquals(normalized) {
            let now = Date()
            changed = true
            entries[index].payload = entries[index].payload.replacingCategory(
                "",
                tags: entries[index].payload.tags
            )
            entries[index].updatedAt = now
            entries[index].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
        }
        guard changed else {
            statusMessage = "Category not found."
            return false
        }
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Category deleted."
        return true
    }

    func renameTag(_ oldValue: String, to newValue: String) -> Bool {
        let oldNormalized = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNormalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldNormalized.isEmpty, !newNormalized.isEmpty else {
            statusMessage = "Value is required."
            return false
        }
        guard !tags.contains(where: {
            !$0.caseInsensitiveEquals(oldNormalized) && $0.caseInsensitiveEquals(newNormalized)
        }) else {
            statusMessage = "Tag already exists."
            return false
        }

        removeTaxonomyValue(oldNormalized, from: &manualTags)
        manualTags.insert(newNormalized)
        for index in entries.indices {
            let updatedTags = entries[index].payload.tags
                .map { $0.caseInsensitiveEquals(oldNormalized) ? newNormalized : $0 }
                .removingDuplicates()
            if updatedTags != entries[index].payload.tags {
                let now = Date()
                entries[index].payload = entries[index].payload.replacingCategory(
                    entries[index].payload.category,
                    tags: updatedTags
                )
                entries[index].updatedAt = now
                entries[index].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
            }
        }
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Tag updated."
        return true
    }

    func deleteTag(_ tag: String) -> Bool {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Value is required."
            return false
        }

        var changed = removeTaxonomyValue(normalized, from: &manualTags)
        for index in entries.indices {
            let updatedTags = entries[index].payload.tags.filter { !$0.caseInsensitiveEquals(normalized) }
            if updatedTags.count != entries[index].payload.tags.count {
                let now = Date()
                changed = true
                entries[index].payload = entries[index].payload.replacingCategory(
                    entries[index].payload.category,
                    tags: updatedTags
                )
                entries[index].updatedAt = now
                entries[index].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
            }
        }
        guard changed else {
            statusMessage = "Tag not found."
            return false
        }
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Tag deleted."
        return true
    }

    func clearAllData(password: String) -> Bool {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before clearing data."
            return false
        }
        guard verifyMasterPassword(password) else {
            return false
        }

        entries = []
        manualCategories = []
        manualTags = []
        categories = []
        tags = []
        requireTotp = false
        totpSecret = ""
        lastBackupStatus = "No backup has run"
        do {
            try markLocalChangesForSync()
            try saveSnapshot()
            statusMessage = "Vault data cleared."
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func runBackup() {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before running backup."
            return
        }
        do {
            try saveSnapshot()
            let backupURL = try repository.createBackup()
            lastBackupStatus = "Backup saved: \(backupURL.lastPathComponent)"
            try saveSnapshot()
            statusMessage = lastBackupStatus
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func listBackups() -> [BackupInfo] {
        do {
            return try repository.listBackups().map { url in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return BackupInfo(
                    fileName: url.lastPathComponent,
                    sizeBytes: attributes[.size] as? Int64 ?? 0,
                    modifiedAt: attributes[.modificationDate] as? Date ?? Date.distantPast
                )
            }
        } catch {
            statusMessage = error.localizedDescription
            return []
        }
    }

    func restoreLatestBackup() {
        guard isUnlocked, let key = activeVaultKey else {
            statusMessage = "Unlock the vault before restoring backup."
            return
        }
        do {
            let backupURL = try repository.restoreLatestBackup()
            loadEnvelopeMetadata()
            try loadSnapshot(key: key)
            lastBackupStatus = "Restored backup: \(backupURL.lastPathComponent)"
            try markLocalChangesForSync()
            try saveSnapshot()
            statusMessage = lastBackupStatus
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restoreBackup(fileName: String) {
        guard isUnlocked, let key = activeVaultKey else {
            statusMessage = "Unlock the vault before restoring backup."
            return
        }
        do {
            let backupURL = try repository.restoreBackup(named: fileName)
            loadEnvelopeMetadata()
            try loadSnapshot(key: key)
            lastBackupStatus = "Restored backup: \(backupURL.lastPathComponent)"
            try markLocalChangesForSync()
            try saveSnapshot()
            statusMessage = lastBackupStatus
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportSnapshot() {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return
        }
        do {
            try saveSnapshot()
            let snapshot = currentSnapshot()
            let exportURL = try repository.saveSnapshotExport(snapshot)
            statusMessage = "Export saved: \(exportURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func makeSnapshotExport() -> VaultExportFile? {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return nil
        }
        do {
            try saveSnapshot()
            let export = try repository.makeSnapshotExport(currentSnapshot())
            statusMessage = "Export ready: \(export.fileName)"
            return export
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func importSnapshot(fileName: String) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before importing."
            return
        }
        do {
            let snapshot = try repository.loadSnapshotImport(named: fileName)
            try applyImportedSnapshot(snapshot)
            statusMessage = "Imported \(entries.filter { !$0.isDeleted }.count) active entries."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importSnapshot(from url: URL) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before importing."
            return
        }
        let canAccess = url.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try repository.decodeSnapshot(data)
            try applyImportedSnapshot(snapshot)
            statusMessage = "Imported \(entries.filter { !$0.isDeleted }.count) active entries."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportEntry(_ entry: VaultEntry) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return
        }
        do {
            let exportURL = try repository.saveEntryExport(entry)
            statusMessage = "Entry export saved: \(exportURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func makeEntryExport(_ entry: VaultEntry, selectedFieldIDs: Set<String>? = nil) -> VaultExportFile? {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return nil
        }
        do {
            let export = try repository.makeEntryExport(entry, selectedFieldIDs: selectedFieldIDs)
            statusMessage = "Entry export ready: \(export.fileName)"
            return export
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func exportCategory(_ category: String) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return
        }
        do {
            let exportedEntries = entries
                .filter { !$0.isDeleted && $0.payload.category == category }
                .sorted { $0.label < $1.label }
            let exportURL = try repository.saveCategoryExport(category: category, entries: exportedEntries)
            statusMessage = "Category export saved: \(exportURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func makeCategoryExport(_ category: String) -> VaultExportFile? {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return nil
        }
        do {
            let exportedEntries = entries
                .filter { !$0.isDeleted && $0.payload.category == category }
                .sorted { $0.label < $1.label }
            let export = try repository.makeCategoryExport(category: category, entries: exportedEntries)
            statusMessage = "Category export ready: \(export.fileName)"
            return export
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func importScopedExport(fileName: String, strategy: ImportConflictStrategy) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before importing."
            return
        }
        do {
            let scopedExport = try repository.loadScopedImport(named: fileName)
            let result = try applyScopedExport(scopedExport, strategy: strategy)
            statusMessage = "Imported \(result.created) created, \(result.updated) updated, \(result.skipped) skipped."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importScopedExport(from url: URL, strategy: ImportConflictStrategy) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before importing."
            return
        }
        let canAccess = url.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let scopedExport = try repository.decodeScopedExport(data)
            let result = try applyScopedExport(scopedExport, strategy: strategy)
            statusMessage = "Imported \(result.created) created, \(result.updated) updated, \(result.skipped) skipped."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func syncNow() {
        guard let client = syncClientFactory.makeClient(settings: syncSettings) else {
            syncStatus = "Not configured"
            statusMessage = "Configure a sync provider before syncing."
            persistUnlockedSnapshot(markLocalChange: false)
            return
        }
        Task {
            await syncNow(client: client)
        }
    }

    func syncNow(client: RemoteSyncClient) async {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before syncing."
            return
        }
        do {
            try saveSnapshot()
            syncStatus = "Syncing..."
            statusMessage = "Sync started."
            let flutterDecoder = FlutterSyncPayloadDecoder(
                masterPassword: masterPassword,
                crypto: crypto
            )
            let result = try await syncEngine.synchronize(
                localSnapshot: currentSnapshot(),
                settings: syncSettings,
                client: client,
                remotePayloadDecoder: flutterDecoder.decode
            )
            try applySyncResult(result)
        } catch {
            recordSyncFailure(error)
        }
    }

    func updateSyncSettings(_ settings: SyncSettings) {
        do {
            var updatedSettings = settings
            updatedSettings.hasLocalChanges = syncSettings.hasLocalChanges
            let savedSettings = try syncSettingsRepository?.save(updatedSettings) ?? updatedSettings
            syncSettings = savedSettings
            let providerLabel = savedSettings.providerType.title
            syncStatus = savedSettings.providerType == .none ? "Not configured" : "Configured: \(providerLabel)"
            statusMessage = "Sync settings saved."
            persistUnlockedSnapshot(markLocalChange: false)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setRequireTotp(_ isRequired: Bool) {
        requireTotp = isRequired
        persistUnlockedSnapshot()
    }

    func setTotpSecret(_ secret: String) {
        totpSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        persistUnlockedSnapshot()
    }

    func filteredEntries(searchText: String, filter: VaultFilter) -> [VaultEntry] {
        let query = VaultSearchQuery.parse(searchText)
        return entries
            .filter { !$0.isDeleted }
            .filter { entry in
                switch filter {
                case .all:
                    true
                case .category(let category):
                    entry.payload.category == category
                case .tag(let tag):
                    entry.payload.tags.contains(tag)
                }
            }
            .filter { entry in
                query.isEmpty || entry.matchesSearchQuery(query)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func seedInitialCollectionsIfNeeded() {
        rebuildCollections()
    }

    private func loadSyncSettings() {
        do {
            if let loaded = try syncSettingsRepository?.load() {
                syncSettings = loaded
                syncStatus = loaded.providerType == .none ? "Not configured" : "Configured: \(loaded.providerType.title)"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func rebuildCollections() {
        let activeEntries = entries.filter { !$0.isDeleted }
        categories = normalizedTaxonomyValues(Array(manualCategories) + activeEntries.map(\.payload.category))
        tags = normalizedTaxonomyValues(Array(manualTags) + activeEntries.flatMap(\.payload.tags))
    }

    private func loadEnvelopeMetadata() {
        do {
            let envelope = try repository.loadEnvelope()
            masterKeyRecord = envelope?.masterKeyRecord
            hasMasterKey = envelope?.masterKeyRecord != nil
            statusMessage = hasMasterKey ? "Encrypted vault found." : nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadSnapshot(key: Data) throws {
        guard let envelope = try repository.loadEnvelope(),
              let encryptedVault = envelope.encryptedVault else {
            entries = []
            categories = []
            tags = []
            manualCategories = []
            manualTags = []
            requireTotp = false
            totpSecret = ""
            syncStatus = "Not configured"
            lastBackupStatus = "No backup has run"
            return
        }
        let decrypted = try crypto.decrypt(encryptedVault, key: key)
        let snapshot = try repository.decodeSnapshot(decrypted)
        entries = snapshot.entries
        manualCategories = Set(normalizedTaxonomyValues(snapshot.categories))
        manualTags = Set(normalizedTaxonomyValues(snapshot.tags))
        requireTotp = snapshot.security.requireTotp
        totpSecret = snapshot.security.totpSecret
        syncStatus = snapshot.syncStatus
        lastBackupStatus = snapshot.lastBackupStatus
        rebuildCollections()
    }

    private static func loadUnlockResult(
        password: String,
        record: MasterKeyRecord,
        vaultURL: URL,
        crypto: VaultCryptoService
    ) async throws -> PreparedUnlockResult {
        try await Task.detached(priority: .userInitiated) {
            let key = try crypto.verify(password: password, record: record)
            guard FileManager.default.fileExists(atPath: vaultURL.path) else {
                return PreparedUnlockResult(key: key, snapshot: nil)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(
                VaultPersistenceEnvelope.self,
                from: try Data(contentsOf: vaultURL)
            )
            guard let encryptedVault = envelope.encryptedVault else {
                return PreparedUnlockResult(key: key, snapshot: nil)
            }
            let decrypted = try crypto.decrypt(encryptedVault, key: key)
            let snapshot = try decoder.decode(VaultSnapshot.self, from: decrypted)
            return PreparedUnlockResult(key: key, snapshot: snapshot)
        }.value
    }

    private func applyUnlockResult(_ result: PreparedUnlockResult, password: String) {
        if let snapshot = result.snapshot {
            entries = snapshot.entries
            manualCategories = Set(normalizedTaxonomyValues(snapshot.categories))
            manualTags = Set(normalizedTaxonomyValues(snapshot.tags))
            requireTotp = snapshot.security.requireTotp
            totpSecret = snapshot.security.totpSecret
            syncStatus = snapshot.syncStatus
            lastBackupStatus = snapshot.lastBackupStatus
            rebuildCollections()
        } else {
            entries = []
            categories = []
            tags = []
            manualCategories = []
            manualTags = []
            requireTotp = false
            totpSecret = ""
            syncStatus = "Not configured"
            lastBackupStatus = "No backup has run"
        }
        masterPassword = password
        activeVaultKey = result.key
        isUnlocked = true
    }

    private func saveSnapshot() throws {
        guard let record = masterKeyRecord,
              let key = activeVaultKey else {
            return
        }
        let snapshot = currentSnapshot()
        let plaintext = try repository.encodeSnapshot(snapshot)
        let encrypted = try crypto.encrypt(plaintext, key: key)
        let envelope = VaultPersistenceEnvelope(
            schemaVersion: 1,
            masterKeyRecord: record,
            encryptedVault: encrypted,
            updatedAt: Date()
        )
        try repository.saveEnvelope(envelope)
    }

    private func currentSnapshot() -> VaultSnapshot {
        VaultSnapshot(
            entries: entries,
            categories: categories,
            tags: tags,
            security: SecuritySettings(requireTotp: requireTotp, totpSecret: totpSecret),
            syncStatus: syncStatus,
            lastBackupStatus: lastBackupStatus,
            updatedAt: Date()
        )
    }

    private func applySyncResult(_ result: VaultSyncEngineResult) throws {
        entries = result.snapshot.entries
        manualCategories = Set(normalizedTaxonomyValues(result.snapshot.categories))
        manualTags = Set(normalizedTaxonomyValues(result.snapshot.tags))
        requireTotp = result.snapshot.security.requireTotp
        totpSecret = result.snapshot.security.totpSecret
        lastBackupStatus = result.snapshot.lastBackupStatus
        syncSettings = result.settings
        syncSettings.hasLocalChanges = false
        syncStatus = result.settings.lastSyncMessage ?? "Sync complete."
        statusMessage = syncStatus
        rebuildCollections()
        try syncSettingsRepository?.save(syncSettings)
        try saveSnapshot()
    }

    private func applyImportedSnapshot(_ snapshot: VaultSnapshot) throws {
        entries = snapshot.entries
        manualCategories = Set(normalizedTaxonomyValues(snapshot.categories))
        manualTags = Set(normalizedTaxonomyValues(snapshot.tags))
        requireTotp = snapshot.security.requireTotp
        totpSecret = snapshot.security.totpSecret
        syncStatus = snapshot.syncStatus
        lastBackupStatus = snapshot.lastBackupStatus
        rebuildCollections()
        try markLocalChangesForSync()
        try saveSnapshot()
    }

    private func applyScopedExport(
        _ scopedExport: ScopedVaultExport,
        strategy: ImportConflictStrategy
    ) throws -> (created: Int, updated: Int, skipped: Int) {
        let importedEntries: [VaultEntry]
        switch scopedExport.scope {
        case .item:
            importedEntries = scopedExport.item.map { [$0] } ?? []
        case .category:
            importedEntries = scopedExport.items ?? []
        }
        let result = applyImportedEntries(importedEntries, strategy: strategy)
        rebuildCollections()
        if result.created > 0 || result.updated > 0 {
            try markLocalChangesForSync()
        }
        try saveSnapshot()
        return result
    }

    private func recordSyncFailure(_ error: Error) {
        var failedSettings = syncSettings
        let message = error.localizedDescription
        failedSettings.lastSyncAt = Date()
        failedSettings.lastSyncStatus = "error"
        failedSettings.lastSyncMessage = message
        failedSettings.logs = ([SyncLogEntry(
            timestamp: Date(),
            message: message,
            level: "error"
        )] + failedSettings.logs).prefix(50).map { $0 }
        syncSettings = failedSettings
        syncStatus = "Sync failed"
        statusMessage = message
        _ = try? syncSettingsRepository?.save(failedSettings)
        persistUnlockedSnapshot(markLocalChange: false)
    }

    private func applyImportedEntries(
        _ importedEntries: [VaultEntry],
        strategy: ImportConflictStrategy
    ) -> (created: Int, updated: Int, skipped: Int) {
        var created = 0
        var updated = 0
        var skipped = 0
        for imported in importedEntries where !imported.isDeleted {
            if let existingIndex = entries.firstIndex(where: { $0.importMatchKey == imported.importMatchKey && !$0.isDeleted }) {
                switch strategy {
                case .skip:
                    skipped += 1
                case .overwrite:
                    entries[existingIndex] = imported.copyForImport(
                        id: entries[existingIndex].id,
                        updatedAt: Date()
                    )
                    updated += 1
                case .keepCopy:
                    entries.append(imported.copyForImport(id: UUID(), updatedAt: Date()))
                    created += 1
                }
            } else {
                entries.append(imported.copyForImport(id: UUID(), updatedAt: Date()))
                created += 1
            }
        }
        return (created, updated, skipped)
    }

    private func validatedTaxonomyValue(
        _ value: String,
        existingValues: [String],
        duplicateMessage: String
    ) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Value is required."
            return nil
        }
        guard !existingValues.contains(where: { $0.caseInsensitiveEquals(normalized) }) else {
            statusMessage = duplicateMessage
            return nil
        }
        return normalized
    }

    private func normalizedTaxonomyValues(_ values: some Sequence<String>) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    @discardableResult
    private func removeTaxonomyValue(_ value: String, from target: inout Set<String>) -> Bool {
        let matches = target.filter { $0.caseInsensitiveEquals(value) }
        for match in matches {
            target.remove(match)
        }
        return !matches.isEmpty
    }

    private func persistUnlockedSnapshot(markLocalChange: Bool = true) {
        guard isUnlocked else { return }
        do {
            if markLocalChange {
                try markLocalChangesForSync()
            }
            try saveSnapshot()
            statusMessage = "Vault saved at \(DateFormatter.shortDateTime.string(from: Date()))"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func markLocalChangesForSync() throws {
        guard !syncSettings.hasLocalChanges else { return }
        syncSettings.hasLocalChanges = true
        try syncSettingsRepository?.save(syncSettings)
    }
}

private extension VaultEntry {
    mutating func markLocalEntryChange(deviceId: String, updatedAt: Date) {
        let updater = deviceId.isEmpty ? (updatedBy.isEmpty ? "macos-native" : updatedBy) : deviceId
        version[updater] = (version[updater] ?? 0) + 1
        updatedBy = updater
        self.updatedAt = updatedAt
    }
}

struct BackupInfo: Identifiable, Equatable {
    var fileName: String
    var sizeBytes: Int64
    var modifiedAt: Date

    var id: String { fileName }
}

struct EntryDraft: Equatable {
    var label = ""
    private var payloadKind: VaultEntryType = .credential
    var credential = CredentialPayload()
    var server = ServerPayload()
    var service = ServicePayload()
    var customFields: [CustomField] = []

    var category: String {
        get { payload.category }
        set {
            credential.category = newValue
            server.category = newValue
            service.category = newValue
        }
    }

    var tags: [String] {
        get { payload.tags }
        set {
            credential.tags = newValue
            server.tags = newValue
            service.tags = newValue
        }
    }

    var payload: VaultPayload {
        switch payloadKind {
        case .credential: .credential(credential)
        case .server: .server(server)
        case .service: .service(service)
        }
    }

    var normalizedCustomFields: [CustomField] {
        customFields
            .map {
                CustomField(
                    id: $0.id,
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    value: $0.value
                )
            }
            .filter { !$0.name.isEmpty || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    init() {}

    init(entry: VaultEntry) {
        label = entry.label
        customFields = entry.customFields
        switch entry.payload {
        case .credential(let payload):
            payloadKind = .credential
            credential = payload
            category = payload.category
            tags = payload.tags
        case .server(let payload):
            payloadKind = .server
            server = payload
            category = payload.category
            tags = payload.tags
        case .service(let payload):
            payloadKind = .service
            service = payload
            category = payload.category
            tags = payload.tags
        }
    }
}

private extension VaultPayload {
    var storageKind: VaultEntryType {
        switch self {
        case .credential:
            .credential
        case .server:
            .server
        case .service:
            .service
        }
    }

    func replacingCategory(_ category: String, tags: [String]) -> VaultPayload {
        switch self {
        case .credential(var payload):
            payload.category = category
            payload.tags = tags
            return .credential(payload)
        case .server(var payload):
            payload.category = category
            payload.tags = tags
            return .server(payload)
        case .service(var payload):
            payload.category = category
            payload.tags = tags
            return .service(payload)
        }
    }
}

private extension Array where Element: Equatable {
    func removingDuplicates() -> [Element] {
        reduce(into: []) { result, element in
            if !result.contains(element) {
                result.append(element)
            }
        }
    }
}

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool {
        compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

private extension VaultEntry {
    var searchIndex: String {
        "\(label) \(payload.category) \(payload.tags.joined(separator: " "))"
    }
}

private extension DateFormatter {
    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
