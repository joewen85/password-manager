import Foundation
import Observation

private enum ImportedEntryAction {
    case create
    case overwrite
    case skip
}

private struct PlannedImportedEntry {
    var imported: VaultEntry
    var destinationID: String
    var action: ImportedEntryAction
}

@Observable
@MainActor
final class VaultStore {
    private(set) var isUnlocked = false
    private(set) var hasMasterKey = false
    private(set) var entries: [VaultEntry] = []
    private(set) var categories: [String] = []
    private(set) var categoryTemplates: [CategoryTemplate] = []
    private(set) var tags: [String] = []
    private(set) var syncStatus = "Not configured"
    private(set) var lastBackupStatus = "No backup has run"
    private(set) var statusMessage: String?
    private(set) var requireTotp = false
    private(set) var totpSecret = ""
    private(set) var syncSettings = SyncSettings.defaults()

    private var categoryStates: [String: CategorySyncState] = [:]
    private var isSyncing = false
    private var syncRequestedAgain = false
    private var localChangeRevision = 0
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
            try recordLocalMutationForSync()
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

    @discardableResult
    func upsert(_ draft: EntryDraft, editing entry: VaultEntry?) -> Bool {
        if let duplicateName = draft.duplicateActiveTemplateBindingName(
            template: categoryTemplate(for: draft.category)
        ) {
            statusMessage = "Field name already exists: \(duplicateName)."
            return false
        }

        let now = Date()
        let payload = draft.payload
        let normalizedTags = draft.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedCategory = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPayload = payload.replacingCategory(normalizedCategory, tags: normalizedTags)
        ensureCategoryIsActive(normalizedCategory, updatedAt: now)

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
        return true
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
            try recordLocalMutationForSync()
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
            categoryTemplates = snapshot.categoryTemplates
            loadCategoryStates(from: snapshot)
            tags = snapshot.tags
            requireTotp = snapshot.security.requireTotp
            totpSecret = snapshot.security.totpSecret
            syncStatus = snapshot.syncStatus
            lastBackupStatus = snapshot.lastBackupStatus
            rebuildCollections()
            try recordLocalMutationForSync()
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
            let exportURL = try repository.saveEntryExport(
                entry,
                selectedFieldIDs: selectedFieldIDs,
                categoryTemplates: categoryTemplates
            )
            statusMessage = "Entry export saved: \(exportURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addCategory(_ category: String) -> Bool {
        addCategory(category, preset: nil)
    }

    func addCategory(_ category: String, preset: CategoryTypePreset?) -> Bool {
        addCategory(category, preset: preset, customFieldNames: [])
    }

    func addCategory(_ category: String, preset: CategoryTypePreset?, customFieldNames: [String]) -> Bool {
        let defaultFieldIDs = Set(CategoryTemplate.defaultFields.map(\.id))
        let customFields = CategoryTemplate.fields(
            for: preset,
            customFieldNames: customFieldNames
        ).filter { !defaultFieldIDs.contains($0.id) }
        return addCategory(category, preset: nil, customFields: customFields)
    }

    func addCategory(_ category: String, preset: CategoryTypePreset?, customFields: [FieldTemplate]) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Category is required."
            return false
        }
        guard !categories.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            statusMessage = "Category already exists."
            return false
        }

        let presetFieldIDs = Set(CategoryTemplate.defaultFields.map(\.id))
        let presetFields = CategoryTemplate.fields(for: preset).filter {
            !presetFieldIDs.contains($0.id)
        }
        let requestedCustomFields = presetFields + customFields
        guard !requestedCustomFields.contains(where: {
            isEditableCategoryFieldType($0.valueType)
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            statusMessage = "Field name is required."
            return false
        }

        let fields = categoryTemplateFieldsForUserSave(
            existing: [],
            requestedCustomFields: requestedCustomFields
        )
        if let duplicateName = duplicateEditableCategoryTemplateFieldName(fields) {
            statusMessage = "Field name already exists: \(duplicateName)."
            return false
        }
        let template = CategoryTemplate(category: normalized, fields: fields)
        let prospectiveTemplates = categoryTemplates + [template]
        guard !fields.contains(where: {
            $0.normalizedValueType == customFieldFieldReferenceValueType
                && !fieldReferenceTemplateConfigurationIsValid(
                    sourceCategory: normalized,
                    sourceField: $0,
                    templates: prospectiveTemplates
                )
        }) else {
            statusMessage = "Field reference requires a target category and target text field."
            return false
        }

        categories.append(normalized)
        categories.sort()
        recordCategoryMutation(normalized, isDeleted: false, updatedAt: Date())
        upsertCategoryTemplate(category: normalized, fields: fields)
        persistUnlockedSnapshot()
        statusMessage = "Category added."
        return true
    }

    func categoryTemplate(for category: String) -> CategoryTemplate? {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return categoryTemplates.first {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    func categoryTemplateStoredValueFieldIds(_ category: String) -> Set<String> {
        guard let template = categoryTemplate(for: category) else { return [] }
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return Set(template.fields.compactMap { templateField in
            let hasStoredValue = entries
                .filter {
                    !$0.isDeleted && $0.payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(normalizedCategory) == .orderedSame
                }
                .flatMap(\.customFields)
                .contains { field in
                    !field.value.isEmpty && field.matchesTemplateField(templateField)
                }
            return hasStoredValue ? templateField.id : nil
        })
    }

    func categoryTemplateReferencedTargetFieldIDs(_ category: String) -> Set<String> {
        fieldReferenceTargetFieldIDs(
            targetCategory: category,
            templates: categoryTemplates
        )
    }

    func updateCategoryTemplate(category: String, requestedCustomFields: [FieldTemplate]) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Category is required."
            return false
        }
        guard !requestedCustomFields.contains(where: {
            isEditableCategoryFieldType($0.valueType)
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            statusMessage = "Field name is required."
            return false
        }

        let existing = categoryTemplate(for: normalized)
            ?? CategoryTemplate(category: normalized)
        let referencedTargetFieldIDs = categoryTemplateReferencedTargetFieldIDs(normalized)
        let requestedFields = CategoryTemplate.defaultFields + requestedCustomFields
        if let protectedField = existing.fields.first(where: { existingField in
            guard existingField.normalizedValueType == customFieldTextValueType,
                  referencedTargetFieldIDs.contains(existingField.id) else {
                return false
            }
            return requestedFields.first(where: { $0.id == existingField.id })?
                .normalizedValueType != customFieldTextValueType
        }) {
            statusMessage = "Referenced field cannot be removed or retyped: \(protectedField.name)."
            return false
        }
        let updatedFields = categoryTemplateFieldsForUserSave(
            existing: existing.fields,
            requestedCustomFields: requestedCustomFields,
            storedValueFieldIds: categoryTemplateStoredValueFieldIds(normalized),
            referencedTargetFieldIds: referencedTargetFieldIDs
        )
        if let duplicateName = duplicateEditableCategoryTemplateFieldName(updatedFields) {
            statusMessage = "Field name already exists: \(duplicateName)."
            return false
        }
        let updated = CategoryTemplate(category: normalized, fields: updatedFields)
        let prospectiveTemplates = categoryTemplates.filter {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalized) != .orderedSame
        } + [updated]
        guard !updatedFields.contains(where: {
            $0.normalizedValueType == customFieldFieldReferenceValueType
                && !fieldReferenceTemplateConfigurationIsValid(
                    sourceCategory: normalized,
                    sourceField: $0,
                    templates: prospectiveTemplates
                )
        }) else {
            statusMessage = "Field reference requires a target category and target text field."
            return false
        }
        if let index = categoryTemplates.firstIndex(where: {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            categoryTemplates[index] = updated
        } else {
            categoryTemplates.append(updated)
        }
        if !categories.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            categories.append(normalized)
            categories.sort()
        }
        categoryTemplates.sort {
            $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
        }
        recordCategoryMutation(normalized, isDeleted: false, updatedAt: Date())
        persistUnlockedSnapshot()
        statusMessage = "Category template updated."
        return true
    }

    func entryReferenceCandidates(targetCategory: String, query: String = "") -> [EntryReferenceCandidate] {
        PasswordManageriOSCore.entryReferenceCandidates(
            entries: entries,
            targetCategory: targetCategory,
            query: query
        )
    }

    func resolveEntryReference(_ field: CustomField, sourceCategory: String) -> EntryReferenceResolution? {
        PasswordManageriOSCore.resolveEntryReference(
            field: field,
            template: categoryTemplate(for: sourceCategory),
            entries: entries
        )
    }

    func liveEntry(_ id: String) -> VaultEntry? {
        entries.first { $0.id == id && !$0.isDeleted }
    }

    @discardableResult
    func updateEntryReference(entryID: String, fieldID: String, targetID: String) -> Bool {
        guard let entryIndex = entries.firstIndex(where: { $0.id == entryID && !$0.isDeleted }),
              let fieldIndex = entries[entryIndex].customFields.firstIndex(where: { $0.id == fieldID }) else {
            statusMessage = "Reference field is no longer available."
            return false
        }
        let field = entries[entryIndex].customFields[fieldIndex]
        let semantics = customFieldSemantics(
            field: field,
            template: categoryTemplate(for: entries[entryIndex].payload.category)
        )
        guard semantics.semantic == .entryReference || semantics.semantic == .fieldReference,
              let templateField = semantics.templateField else {
            statusMessage = "Reference field is no longer available."
            return false
        }
        if semantics.semantic == .fieldReference,
           !fieldReferenceTemplateConfigurationIsValid(
               sourceCategory: entries[entryIndex].payload.category,
               sourceField: templateField,
               templates: categoryTemplates
           ) {
            statusMessage = "Field reference configuration needs repair."
            return false
        }
        if !targetID.isEmpty {
            guard entryReferenceCandidates(targetCategory: templateField.targetCategory)
                .contains(where: { $0.id == targetID }) else {
                statusMessage = "Selected entry is not available for this field."
                return false
            }
        }

        let now = Date()
        entries[entryIndex].customFields[fieldIndex].value = targetID
        entries[entryIndex].updatedAt = now
        entries[entryIndex].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
        persistUnlockedSnapshot()
        statusMessage = targetID.isEmpty ? "Reference cleared." : "Reference updated."
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
            let exportURL = try repository.saveCategoryExport(
                category: category,
                entries: exportedEntries,
                categoryTemplates: categoryTemplates
            )
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
            let templatesChanged = mergeImportedCategoryTemplates(scopedExport.categoryTemplates)
            let importedEntries: [VaultEntry]
            switch scopedExport.scope {
            case .item:
                importedEntries = scopedExport.item.map { [$0] } ?? []
            case .category:
                importedEntries = scopedExport.items ?? []
            }
            let result = applyImportedEntries(importedEntries, strategy: strategy)
            rebuildCollections()
            if templatesChanged || result.created > 0 || result.updated > 0 {
                try recordLocalMutationForSync()
            }
            try saveSnapshot()
            statusMessage = "Imported \(result.created) created, \(result.updated) updated, \(result.skipped) skipped."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func syncNow() {
        guard beginSyncIfPossible() else { return }
        guard let client = syncClientFactory.makeClient(settings: syncSettings) else {
            isSyncing = false
            syncStatus = "Not configured"
            statusMessage = "Configure a sync provider before syncing."
            persistUnlockedSnapshot(markLocalChange: false)
            return
        }
        Task {
            await performSyncLoop(client: client)
        }
    }

    func syncNow(client: RemoteSyncClient) async {
        guard beginSyncIfPossible() else { return }
        await performSyncLoop(client: client)
    }

    private func beginSyncIfPossible() -> Bool {
        if isSyncing {
            syncRequestedAgain = true
            return false
        }
        guard isUnlocked else {
            statusMessage = "Unlock the vault before syncing."
            return false
        }
        isSyncing = true
        return true
    }

    private func performSyncLoop(client: RemoteSyncClient) async {
        defer { isSyncing = false }

        repeat {
            syncRequestedAgain = false
            let revisionAtStart = localChangeRevision
            do {
                try saveSnapshot()
                syncStatus = "Syncing..."
                statusMessage = "Sync started."
                guard let vaultKey = activeVaultKey else {
                    throw VaultSyncEngineError.invalidRemotePayload
                }
                let encryptedClient = EncryptedRemoteSyncClient(
                    delegate: client,
                    crypto: crypto,
                    vaultKey: vaultKey,
                    masterKeyRecord: masterKeyRecord,
                    includeMasterKeyRecord: syncSettings.syncMasterKey
                )
                let result = try await syncEngine.synchronize(
                    localSnapshot: currentSnapshot(),
                    settings: syncSettings,
                    client: encryptedClient,
                    shouldCancelUpload: { [weak self] in
                        await MainActor.run {
                            self?.localChangeRevision != revisionAtStart
                        }
                    }
                )
                if encryptedClient.downloadedPlaintextRemote, !result.uploaded {
                    guard revisionAtStart == localChangeRevision else {
                        syncRequestedAgain = true
                        continue
                    }
                    let migrationPayload = VaultSyncPayload(
                        exportedAt: Date(),
                        deviceId: syncSettings.deviceId,
                        revision: result.settings.lastSyncRevision,
                        snapshot: result.snapshot
                    )
                    let migration = await encryptedClient.upload(try syncEngine.encodePayload(migrationPayload))
                    guard migration.statusCode >= 200 && migration.statusCode < 300 else {
                        throw VaultSyncEngineError.uploadFailed(migration.statusCode)
                    }
                }
                guard revisionAtStart == localChangeRevision else {
                    syncRequestedAgain = true
                    continue
                }
                try applySyncResult(result)
            } catch {
                if let syncError = error as? VaultSyncEngineError, syncError == .syncCancelled {
                    syncRequestedAgain = true
                    continue
                }
                recordSyncFailure(error)
            }
        } while syncRequestedAgain
    }

    func hasSyncInProgressForTesting() -> Bool {
        isSyncing
    }

    func syncWasRequestedAgainForTesting() -> Bool {
        syncRequestedAgain
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
        let query = VaultSearchQuery.parse(searchText)
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
                query.isEmpty || entry.withFieldReferenceSearchProjection(
                    categoryTemplates: categoryTemplates,
                    entries: entries
                ).matchesSearchQuery(query)
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
        let deletedCategoryKeys = Set(categoryStates.values.compactMap { state in
            state.isDeleted ? state.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
        })
        let activeStateCategories = categoryStates.values.compactMap { state in
            state.isDeleted ? nil : state.name
        }
        categories = Array(Set(
            existingCategories + activeStateCategories + activeEntries.map(\.payload.category).filter { !$0.isEmpty }
        )).filter { !deletedCategoryKeys.contains($0.lowercased()) }.sorted()
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
            categoryTemplates = []
            categoryStates = [:]
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
        categoryTemplates = snapshot.categoryTemplates
        loadCategoryStates(from: snapshot)
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
            categoryTemplates: categoryTemplates,
            categoryStates: categoryStates.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
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
        categoryTemplates = result.snapshot.categoryTemplates
        loadCategoryStates(from: result.snapshot)
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
        var destinationIDsByMatchKey: [String: String] = [:]
        for existing in entries where !existing.isDeleted && destinationIDsByMatchKey[existing.importMatchKey] == nil {
            destinationIDsByMatchKey[existing.importMatchKey] = existing.id
        }

        var plannedImports: [PlannedImportedEntry] = []
        for imported in importedEntries where !imported.isDeleted {
            if let existingID = destinationIDsByMatchKey[imported.importMatchKey] {
                let action: ImportedEntryAction
                switch strategy {
                case .skip:
                    action = .skip
                case .overwrite:
                    action = .overwrite
                case .keepCopy:
                    action = .create
                }
                plannedImports.append(PlannedImportedEntry(
                    imported: imported,
                    destinationID: action == .create ? UUID().uuidString.lowercased() : existingID,
                    action: action
                ))
            } else {
                let destinationID = UUID().uuidString.lowercased()
                destinationIDsByMatchKey[imported.importMatchKey] = destinationID
                plannedImports.append(PlannedImportedEntry(
                    imported: imported,
                    destinationID: destinationID,
                    action: .create
                ))
            }
        }

        var destinationIDsBySourceID: [String: String] = [:]
        for plan in plannedImports where !plan.imported.id.isEmpty {
            destinationIDsBySourceID[plan.imported.id] = plan.destinationID
        }

        var created = 0
        var updated = 0
        var skipped = 0
        for plan in plannedImports {
            let template = categoryTemplates.first {
                $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(
                        plan.imported.payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
                    ) == .orderedSame
            }
            let imported = plan.imported
                .remappingEntryReferenceIDs(
                    using: destinationIDsBySourceID,
                    template: template
                )
                .remappingFieldReferenceIDs(
                    using: destinationIDsBySourceID,
                    template: template
                )
            switch plan.action {
            case .skip:
                skipped += 1
            case .create:
                entries.append(imported.copyForImport(id: plan.destinationID, updatedAt: Date()))
                created += 1
            case .overwrite:
                guard let existingIndex = entries.firstIndex(where: { $0.id == plan.destinationID }) else {
                    preconditionFailure("Planned import target is missing.")
                }
                entries[existingIndex] = imported.copyForImport(
                    id: plan.destinationID,
                    updatedAt: Date()
                )
                updated += 1
            }
        }
        return (created, updated, skipped)
    }

    private func persistUnlockedSnapshot(markLocalChange: Bool = true) {
        guard isUnlocked else { return }
        do {
            if markLocalChange {
                try recordLocalMutationForSync()
            }
            try saveSnapshot()
            statusMessage = "Vault saved at \(DateFormatter.shortDateTime.string(from: Date()))"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func recordLocalMutationForSync() throws {
        localChangeRevision += 1
        if isSyncing {
            syncRequestedAgain = true
        }
        try markLocalChangesForSync()
    }

    private func markLocalChangesForSync() throws {
        guard !syncSettings.hasLocalChanges else { return }
        syncSettings.hasLocalChanges = true
        try syncSettingsRepository?.save(syncSettings)
    }

    private func upsertCategoryTemplate(category: String, fields: [FieldTemplate]) {
        guard !fields.isEmpty else { return }
        let template = CategoryTemplate(category: category, fields: fields)
        if let index = categoryTemplates.firstIndex(where: {
            $0.category.caseInsensitiveCompare(category) == .orderedSame
        }) {
            categoryTemplates[index] = template
        } else {
            categoryTemplates.append(template)
        }
        categoryTemplates.sort {
            $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
        }
    }

    private func mergeImportedCategoryTemplates(_ importedTemplates: [CategoryTemplate]) -> Bool {
        var changed = false
        for importedTemplate in importedTemplates {
            let importedCategory = importedTemplate.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !importedCategory.isEmpty else { continue }
            var templateChanged = false
            if !categories.contains(where: { $0.caseInsensitiveCompare(importedCategory) == .orderedSame }) {
                categories.append(importedCategory)
                changed = true
            }
            ensureCategoryIsActive(importedCategory, updatedAt: Date())
            if let templateIndex = categoryTemplates.firstIndex(where: {
                $0.category.caseInsensitiveCompare(importedCategory) == .orderedSame
            }) {
                var mergedTemplate = categoryTemplates[templateIndex]
                for importedField in importedTemplate.fields {
                    if let fieldIndex = mergedTemplate.fields.firstIndex(where: { $0.id == importedField.id }) {
                        if mergedTemplate.fields[fieldIndex] != importedField {
                            mergedTemplate.fields[fieldIndex] = importedField
                            changed = true
                            templateChanged = true
                        }
                    } else {
                        mergedTemplate.fields.append(importedField)
                        changed = true
                        templateChanged = true
                    }
                }
                categoryTemplates[templateIndex] = mergedTemplate
            } else {
                categoryTemplates.append(CategoryTemplate(category: importedCategory, fields: importedTemplate.fields))
                changed = true
                templateChanged = true
            }
            if templateChanged {
                recordCategoryMutation(importedCategory, isDeleted: false, updatedAt: Date())
            }
        }
        categories.sort()
        categoryTemplates.sort {
            $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
        }
        return changed
    }

    private func loadCategoryStates(from snapshot: VaultSnapshot) {
        var loaded: [String: CategorySyncState] = [:]
        for state in snapshot.categoryStates {
            let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let normalized = normalizedCategoryState(state, name: name)
            let key = name.lowercased()
            if let existing = loaded[key] {
                loaded[key] = preferredCategoryState(existing, normalized)
            } else {
                loaded[key] = normalized
            }
        }
        let legacyNames = snapshot.categories
            + snapshot.categoryTemplates.map(\.category)
            + snapshot.entries.filter { !$0.isDeleted }.map(\.payload.category)
        for rawName in legacyNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, loaded[key] == nil else { continue }
            loaded[key] = CategorySyncState(
                name: name,
                updatedAt: snapshot.updatedAt,
                version: ["legacy": 1],
                updatedBy: "legacy"
            )
        }
        categoryStates = loaded
    }

    private func normalizedCategoryState(_ state: CategorySyncState, name: String) -> CategorySyncState {
        let updater = state.updatedBy.isEmpty ? "legacy" : state.updatedBy
        return CategorySyncState(
            name: name,
            isDeleted: state.isDeleted,
            updatedAt: state.updatedAt,
            version: state.version.isEmpty ? [updater: 1] : state.version,
            updatedBy: updater
        )
    }

    private func preferredCategoryState(
        _ existing: CategorySyncState,
        _ candidate: CategorySyncState
    ) -> CategorySyncState {
        switch VaultSyncMerger.compareVersion(local: existing.version, remote: candidate.version) {
        case .localDominates:
            existing
        case .remoteDominates:
            candidate
        case .equal, .concurrent:
            if existing.isDeleted != candidate.isDeleted {
                existing.isDeleted ? existing : candidate
            } else {
                existing.updatedAt >= candidate.updatedAt ? existing : candidate
            }
        }
    }

    private func ensureCategoryIsActive(_ category: String, updatedAt: Date) {
        let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existing = categoryStates[name.lowercased()]
        guard existing == nil || existing?.isDeleted == true else { return }
        recordCategoryMutation(name, isDeleted: false, updatedAt: updatedAt)
    }

    private func recordCategoryMutation(_ category: String, isDeleted: Bool, updatedAt: Date) {
        let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let key = name.lowercased()
        let updater = syncSettings.deviceId.isEmpty ? "ios-native" : syncSettings.deviceId
        var version = categoryStates[key]?.version ?? [:]
        version[updater] = (version[updater] ?? 0) + 1
        categoryStates[key] = CategorySyncState(
            name: name,
            isDeleted: isDeleted,
            updatedAt: updatedAt,
            version: version,
            updatedBy: updater
        )
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
    private(set) var protectedCustomFieldIds: Set<String> = []
    private(set) var hiddenCustomFieldIds: Set<String> = []
    private var customFieldSourceCategories: [String: String] = [:]

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
        let currentCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return customFields.compactMap { field in
            if let sourceCategory = customFieldSourceCategories[field.id],
               !sameCategory(sourceCategory, currentCategory) {
                return nil
            }
            if protectedCustomFieldIds.contains(field.id) {
                return field
            }
            let normalized = CustomField(
                id: field.id,
                templateFieldId: field.templateFieldId,
                name: field.name.trimmingCharacters(in: .whitespacesAndNewlines),
                value: field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return normalized.name.isEmpty && normalized.value.isEmpty ? nil : normalized
        }
    }

    init() {}

    init(category: String, templateFields: [FieldTemplate]) {
        self.init()
        self.category = category
        configureTemplateFields(templateFields)
    }

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

    mutating func addCustomField(_ field: CustomField = CustomField()) {
        customFields.append(field)
        customFieldSourceCategories[field.id] = category.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func duplicateActiveTemplateBindingName(template: CategoryTemplate?) -> String? {
        let currentCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        for templateField in template?.fields ?? []
        where templateField.normalizedValueType == customFieldTextValueType
            || templateField.normalizedValueType == customFieldEntryReferenceValueType
            || templateField.normalizedValueType == customFieldFieldReferenceValueType {
            let activeBindingCount = customFields.lazy.filter { field in
                guard field.matchesTemplateField(templateField) else { return false }
                guard let sourceCategory = customFieldSourceCategories[field.id] else { return true }
                return sameCategory(sourceCategory, currentCategory)
            }.prefix(2).count
            if activeBindingCount > 1 {
                return templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    mutating func configureTemplateFields(_ fields: [FieldTemplate]) {
        let targetCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = CategoryTemplate(category: targetCategory, fields: fields)
        var usedIndices = Set<Int>()
        var seenNames = Set<String>()
        var configuredFields: [CustomField] = []
        var nextSources: [String: String] = [:]
        var nextProtectedIds = Set<String>()
        var nextHiddenIds = Set<String>()

        for templateField in fields {
            guard templateField.normalizedValueType == customFieldTextValueType
                    || templateField.normalizedValueType == customFieldEntryReferenceValueType
                    || templateField.normalizedValueType == customFieldFieldReferenceValueType else {
                continue
            }
            let name = templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameKey = name.lowercased()
            guard !name.isEmpty,
                  name.caseInsensitiveCompare("名称") != .orderedSame,
                  seenNames.insert(nameKey).inserted else {
                continue
            }

            let matchingIndices = customFields.indices.filter { index in
                !usedIndices.contains(index) && customFields[index].matchesTemplateField(templateField)
            }
            let sameSourceIndices = matchingIndices.filter {
                guard let sourceCategory = customFieldSourceCategories[customFields[$0].id] else {
                    return false
                }
                return sameCategory(sourceCategory, targetCategory)
            }
            let unknownSourceIndices = matchingIndices.filter {
                customFieldSourceCategories[customFields[$0].id] == nil
            }
            let existingIndex = sameSourceIndices.first {
                customFields[$0].nameMatches(templateField)
            } ?? sameSourceIndices.first ?? unknownSourceIndices.first {
                customFields[$0].nameMatches(templateField)
            } ?? unknownSourceIndices.first
            let existing = existingIndex.map { customFields[$0] }
            if let existingIndex { usedIndices.insert(existingIndex) }
            let configured: CustomField
            if templateField.normalizedValueType != customFieldTextValueType,
               var existing {
                if existing.templateFieldId.isEmpty {
                    existing.templateFieldId = templateField.id
                }
                configured = existing
            } else {
                configured = CustomField(
                    id: existing?.id ?? UUID().uuidString.lowercased(),
                    templateFieldId: templateField.id,
                    name: name,
                    value: existing?.value ?? ""
                )
            }
            configuredFields.append(configured)
            nextSources[configured.id] = targetCategory
            if templateField.normalizedValueType == customFieldEntryReferenceValueType
                || templateField.normalizedValueType == customFieldFieldReferenceValueType {
                nextProtectedIds.insert(configured.id)
            }
        }

        for index in customFields.indices where !usedIndices.contains(index) {
            let field = customFields[index]
            configuredFields.append(field)
            let sourceCategory = customFieldSourceCategories[field.id]
            if let sourceCategory {
                nextSources[field.id] = sourceCategory
            }
            let duplicatesActiveBinding = fields.contains { templateField in
                (templateField.normalizedValueType == customFieldTextValueType
                    || templateField.normalizedValueType == customFieldEntryReferenceValueType
                    || templateField.normalizedValueType == customFieldFieldReferenceValueType)
                    && field.matchesTemplateField(templateField)
            }
            let isHidden = sourceCategory.map { !sameCategory($0, targetCategory) } ?? false
                || duplicatesActiveBinding
                || customFieldSemantics(field: field, template: template).semantic == .unsupported
            if isHidden {
                nextHiddenIds.insert(field.id)
                nextProtectedIds.insert(field.id)
            }
        }

        customFields = configuredFields
        customFieldSourceCategories = nextSources
        protectedCustomFieldIds = nextProtectedIds
        hiddenCustomFieldIds = nextHiddenIds
    }
}

private extension CustomField {
    func matchesTemplateField(_ templateField: FieldTemplate) -> Bool {
        if !templateFieldId.isEmpty {
            return templateFieldId == templateField.id
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(
                templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }

    func nameMatches(_ templateField: FieldTemplate) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(
                templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }
}

private func sameCategory(_ left: String, _ right: String) -> Bool {
    left.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(right.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
}

extension VaultPayload {
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
