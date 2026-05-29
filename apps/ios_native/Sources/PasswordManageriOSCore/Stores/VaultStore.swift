import Foundation
import Observation

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

    func lock() {
        isUnlocked = false
        masterPassword = ""
        activeVaultKey = nil
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
            entries[index].type = draft.type
            entries[index].payload = finalPayload
            entries[index].customFields = draft.normalizedCustomFields
            entries[index].updatedAt = now
            entries[index].isDeleted = false
            entries[index].deletedAt = nil
            entries[index].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
        } else {
            var newEntry = VaultEntry(
                label: draft.label,
                type: draft.type,
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

    func importSnapshot(fileName: String) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before importing."
            return
        }
        do {
            let snapshot = try repository.loadSnapshotImport(named: fileName)
            entries = snapshot.entries
            categories = snapshot.categories
            tags = snapshot.tags
            requireTotp = snapshot.security.requireTotp
            totpSecret = snapshot.security.totpSecret
            syncStatus = snapshot.syncStatus
            lastBackupStatus = snapshot.lastBackupStatus
            rebuildCollections()
            try markLocalChangesForSync()
            try saveSnapshot()
            statusMessage = "Imported \(entries.filter { !$0.isDeleted }.count) active entries."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportEntry(_ entry: VaultEntry, selectedFieldIDs: Set<String>? = nil) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return
        }
        do {
            let exportURL = try repository.saveEntryExport(entry, selectedFieldIDs: selectedFieldIDs)
            statusMessage = "Entry export saved: \(exportURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addCategory(_ category: String) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Category is required."
            return false
        }
        guard !categories.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            statusMessage = "Category already exists."
            return false
        }
        categories.append(normalized)
        categories.sort()
        persistUnlockedSnapshot()
        statusMessage = "Category added."
        return true
    }

    func addTag(_ tag: String) -> Bool {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Tag is required."
            return false
        }
        guard !tags.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            statusMessage = "Tag already exists."
            return false
        }
        tags.append(normalized)
        tags.sort()
        persistUnlockedSnapshot()
        statusMessage = "Tag added."
        return true
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

    func importScopedExport(fileName: String, strategy: ImportConflictStrategy) {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before importing."
            return
        }
        do {
            let scopedExport = try repository.loadScopedImport(named: fileName)
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
            let result = try await syncEngine.synchronize(
                localSnapshot: currentSnapshot(),
                settings: syncSettings,
                client: client
            )
            try applySyncResult(result)
        } catch {
            recordSyncFailure(error)
        }
    }

    func updateSyncSettings(_ settings: SyncSettings) {
        let hadLocalChanges = syncSettings.hasLocalChanges
        syncSettings = settings
        syncSettings.hasLocalChanges = hadLocalChanges
        do {
            try syncSettingsRepository?.save(syncSettings)
            let providerLabel = settings.providerType.title
            syncStatus = settings.providerType == .none ? "Not configured" : "Configured: \(providerLabel)"
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries
            .filter { !$0.isDeleted }
            .filter { entry in
                switch filter {
                case .all:
                    true
                case .type(let type):
                    entry.type == type
                case .category(let category):
                    entry.payload.category == category
                case .tag(let tag):
                    entry.payload.tags.contains(tag)
                }
            }
            .filter { entry in
                query.isEmpty || entry.searchIndex.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func seedInitialCollectionsIfNeeded() {
        if categories.isEmpty {
            categories = ["Default"]
        }
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
        let existingCategories = categories
        let existingTags = tags
        let activeEntries = entries.filter { !$0.isDeleted }
        categories = Array(Set(existingCategories + activeEntries.map(\.payload.category).filter { !$0.isEmpty })).sorted()
        tags = Array(Set(existingTags + activeEntries.flatMap(\.payload.tags))).sorted()
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
            requireTotp = false
            totpSecret = ""
            syncStatus = "Not configured"
            lastBackupStatus = "No backup has run"
            return
        }
        let decrypted = try crypto.decrypt(encryptedVault, key: key)
        let snapshot = try repository.decodeSnapshot(decrypted)
        entries = snapshot.entries
        categories = snapshot.categories
        tags = snapshot.tags
        requireTotp = snapshot.security.requireTotp
        totpSecret = snapshot.security.totpSecret
        syncStatus = snapshot.syncStatus
        lastBackupStatus = snapshot.lastBackupStatus
        rebuildCollections()
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
        categories = result.snapshot.categories
        tags = result.snapshot.tags
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
        try? syncSettingsRepository?.save(failedSettings)
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
        let updater = deviceId.isEmpty ? (updatedBy.isEmpty ? "ios-native" : updatedBy) : deviceId
        version[updater] = (version[updater] ?? 0) + 1
        updatedBy = updater
        self.updatedAt = updatedAt
    }
}

struct EntryDraft: Equatable {
    var label = ""
    var type: VaultEntryType = .credential
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
        switch type {
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
                    value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.name.isEmpty || !$0.value.isEmpty }
    }

    init() {}

    init(entry: VaultEntry) {
        label = entry.label
        type = entry.type
        customFields = entry.customFields
        switch entry.payload {
        case .credential(let payload):
            credential = payload
            category = payload.category
            tags = payload.tags
        case .server(let payload):
            server = payload
            category = payload.category
            tags = payload.tags
        case .service(let payload):
            service = payload
            category = payload.category
            tags = payload.tags
        }
    }
}

private extension VaultPayload {
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

private extension VaultEntry {
    var searchIndex: String {
        "\(label) \(type.rawValue) \(payload.category) \(payload.tags.joined(separator: " "))"
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
