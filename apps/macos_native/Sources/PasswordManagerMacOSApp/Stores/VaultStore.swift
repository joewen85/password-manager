import Foundation
import Observation

private struct PreparedUnlockResult: Sendable {
    var key: Data
    var snapshot: VaultSnapshot?
}

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

    private var manualCategories: Set<String> = []
    private var categoryStates: [String: CategorySyncState] = [:]
    private var manualTags: Set<String> = []
    private(set) var isSyncing = false
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
        ensureCategoryIsActive(normalizedCategory, updatedAt: now)

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

    func addCategory(
        _ category: String,
        preset: CategoryTypePreset? = nil,
        customFieldNames: [String] = []
    ) -> Bool {
        let defaultFieldIDs = Set(CategoryTemplate.defaultCategoryFields().map(\.id))
        let customFields = CategoryTemplate.fields(
            for: preset,
            customFieldNames: customFieldNames
        ).filter { !defaultFieldIDs.contains($0.id) }
        return addCategory(category, preset: nil, customFields: customFields)
    }

    func addCategory(
        _ category: String,
        preset: CategoryTypePreset? = nil,
        customFields: [FieldTemplate]
    ) -> Bool {
        guard let normalized = validatedTaxonomyValue(
            category,
            existingValues: categories,
            duplicateMessage: "Category already exists."
        ) else {
            return false
        }

        let defaultFields = CategoryTemplate.defaultCategoryFields()
        let defaultFieldIDs = Set(defaultFields.map(\.id))
        let presetFields = CategoryTemplate.fields(for: preset).filter {
            !defaultFieldIDs.contains($0.id)
        }
        let requestedFields = presetFields + customFields
        guard !requestedFields.contains(where: {
            isEditableCategoryFieldType($0.valueType)
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            statusMessage = "Field name is required."
            return false
        }

        var editableFieldNames: [String] = []
        for field in defaultFields + requestedFields where isEditableCategoryFieldType(field.valueType) {
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if editableFieldNames.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
                statusMessage = "Field name already exists: \(name)."
                return false
            }
            editableFieldNames.append(name)
        }

        let fields = CategoryTemplate(
            category: normalized,
            fields: defaultFields + requestedFields
        ).fields
        let template = CategoryTemplate(category: normalized, fields: fields)
        let prospectiveTemplates = categoryTemplates + [template]
        guard !fields.contains(where: {
            $0.normalizedValueType == "fieldReference"
                && !fieldReferenceTemplateConfigurationIsValid(
                    sourceCategory: normalized,
                    sourceField: $0,
                    templates: prospectiveTemplates
                )
        }) else {
            statusMessage = "Field reference requires a target category and target text field."
            return false
        }

        manualCategories.insert(normalized)
        recordCategoryMutation(normalized, isDeleted: false, updatedAt: Date())
        upsertCategoryTemplate(category: normalized, fields: fields)
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
        let now = Date()
        recordCategoryMutation(oldNormalized, isDeleted: true, updatedAt: now)
        recordCategoryMutation(newNormalized, isDeleted: false, updatedAt: now)
        renameCategoryTemplate(oldValue: oldNormalized, to: newNormalized)
        categoryTemplates = propagateEntryReferenceCategoryRename(
            templates: categoryTemplates,
            from: oldNormalized,
            to: newNormalized
        )
        categoryTemplates = propagateFieldReferenceCategoryRename(
            templates: categoryTemplates,
            from: oldNormalized,
            to: newNormalized
        )
        for index in entries.indices where entries[index].payload.category.caseInsensitiveEquals(oldNormalized) {
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

    func updateCategoryTemplate(_ category: String, customFieldNames: [String]) -> Bool {
        let existingFields = categoryTemplates
            .first { $0.category.caseInsensitiveEquals(category) }?
            .fields ?? []
        let customFields = CategoryTemplate.fields(for: nil, customFieldNames: customFieldNames)
            .filter { !$0.name.caseInsensitiveEquals("名称") }
            .map { field in
                let name = field.name
                let existing = existingFields.first {
                    $0.valueType == "text" && $0.name.caseInsensitiveEquals(name)
                }
                return CustomField(
                    templateFieldId: existing?.id ?? "",
                    name: name
                )
            }
        return updateCategoryTemplate(category, customFields: customFields)
    }

    func updateCategoryTemplate(_ category: String, customFields: [CustomField]) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingFields = categoryTemplates
            .first { $0.category.caseInsensitiveEquals(normalized) }?
            .fields ?? CategoryTemplate.defaultCategoryFields()
        let protectedFieldNames = Set(existingFields.filter {
            $0.normalizedValueType != "text"
        }.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var requestedFields: [FieldTemplate] = customFields.compactMap { customField in
            let name = customField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !name.caseInsensitiveEquals("名称") else {
                return nil
            }
            let exactExistingField = existingFields.first {
                !customField.templateFieldId.isEmpty && $0.id == customField.templateFieldId
            }
            guard exactExistingField != nil || !protectedFieldNames.contains(name.lowercased()) else {
                return nil
            }
            let existingField = exactExistingField ?? existingFields.first {
                $0.normalizedValueType == "text" && $0.name.caseInsensitiveEquals(name)
            }
            return FieldTemplate(
                id: existingField?.id ?? customField.templateFieldId,
                name: name,
                valueType: existingField?.valueType ?? "text",
                targetCategory: existingField?.targetCategory ?? "",
                targetFieldId: existingField?.targetFieldId ?? ""
            )
        }
        let requestedIDs = Set(requestedFields.map(\.id))
        requestedFields.append(contentsOf: existingFields.filter {
            !isEditableCategoryFieldType($0.valueType) && !requestedIDs.contains($0.id)
        })
        return updateCategoryTemplate(category, fields: requestedFields)
    }

    func updateCategoryTemplate(_ category: String, fields requestedFields: [FieldTemplate]) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Value is required."
            return false
        }
        guard let canonicalCategory = categories.first(where: { $0.caseInsensitiveEquals(normalized) }) else {
            statusMessage = "Category not found."
            return false
        }

        let existingFields = categoryTemplates
            .first { $0.category.caseInsensitiveEquals(canonicalCategory) }?
            .fields ?? CategoryTemplate.defaultCategoryFields()
        let nameField = existingFields.first { $0.name.caseInsensitiveEquals("名称") }
            ?? CategoryTemplate.defaultCategoryFields()[0]
        let storedValueFieldIDs = categoryTemplateStoredValueFieldIDs(canonicalCategory)
        let requestedByID = Dictionary(
            requestedFields.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let referencedTargetFieldIDs = categoryTemplateReferencedTargetFieldIDs(canonicalCategory)
        if let protectedField = existingFields.first(where: { existingField in
            guard existingField.id != nameField.id,
                  existingField.normalizedValueType == "text",
                  referencedTargetFieldIDs.contains(existingField.id) else {
                return false
            }
            return requestedByID[existingField.id]?.normalizedValueType != "text"
        }) {
            statusMessage = "Referenced field cannot be removed or retyped: \(protectedField.name)."
            return false
        }
        let mandatoryFields = existingFields.filter {
            storedValueFieldIDs.contains($0.id)
                || !isEditableCategoryFieldType($0.valueType)
        }
        var claimedMandatoryNames = Set([nameField.name.lowercased()])
        var mandatoryFinalFields: [FieldTemplate] = []
        for existing in mandatoryFields {
            let isUnknown = !isEditableCategoryFieldType(existing.valueType)
            if isUnknown {
                claimedMandatoryNames.insert(
                    existing.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
                mandatoryFinalFields.append(existing)
                continue
            }
            let requested = requestedByID[existing.id]
            let requestedName = requested?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let requestedNameKey = requestedName.lowercased()
            let conflictsWithMandatoryField = mandatoryFields.contains {
                $0.id != existing.id
                    && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == requestedNameKey
            }
            let canRename = !requestedName.isEmpty
                && !requestedName.caseInsensitiveEquals("名称")
                && !conflictsWithMandatoryField
                && !claimedMandatoryNames.contains(requestedNameKey)
            let name = canRename ? requestedName : existing.name
            claimedMandatoryNames.insert(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            mandatoryFinalFields.append(FieldTemplate(
                id: existing.id,
                name: name,
                valueType: existing.normalizedValueType,
                targetCategory: existing.normalizedValueType == "fieldReference"
                    ? (requested?.targetCategory ?? existing.targetCategory)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : "",
                targetFieldId: existing.normalizedValueType == "fieldReference"
                    ? requested?.targetFieldId ?? existing.targetFieldId
                    : ""
            ))
        }
        let reservedMandatoryNames = Set(mandatoryFinalFields.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var updatedFields = [nameField]
        var includedIDs = Set([nameField.id])
        var includedNames = Set([nameField.name.lowercased()])

        for requested in requestedFields {
            let existing = existingFields.first { $0.id == requested.id }
            if let mandatory = mandatoryFinalFields.first(where: { $0.id == requested.id }) {
                appendTemplateField(
                    mandatory,
                    to: &updatedFields,
                    includedIDs: &includedIDs,
                    includedNames: &includedNames
                )
                continue
            }

            let name = requested.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.caseInsensitiveEquals("名称") else { continue }
            guard !reservedMandatoryNames.contains(name.lowercased()) else { continue }
            let requestedType = requested.normalizedValueType
            guard isEditableCategoryFieldType(requestedType) else { continue }

            let targetCategory = requestedType == "fieldReference"
                ? requested.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let field = FieldTemplate(
                id: existing?.id ?? requested.id,
                name: name,
                valueType: requestedType,
                targetCategory: targetCategory,
                targetFieldId: requestedType == "fieldReference" ? requested.targetFieldId : ""
            )
            appendTemplateField(
                field,
                to: &updatedFields,
                includedIDs: &includedIDs,
                includedNames: &includedNames
            )
        }

        for mandatory in mandatoryFinalFields where !includedIDs.contains(mandatory.id) {
            appendTemplateField(
                mandatory,
                to: &updatedFields,
                includedIDs: &includedIDs,
                includedNames: &includedNames
            )
        }

        let updated = CategoryTemplate(category: canonicalCategory, fields: updatedFields)
        let prospectiveTemplates = categoryTemplates.filter {
            !$0.category.caseInsensitiveEquals(canonicalCategory)
        } + [updated]
        guard !updatedFields.contains(where: {
            $0.normalizedValueType == "fieldReference"
                && !fieldReferenceTemplateConfigurationIsValid(
                    sourceCategory: canonicalCategory,
                    sourceField: $0,
                    templates: prospectiveTemplates
                )
        }) else {
            statusMessage = "Field reference requires a target category and target text field."
            return false
        }

        upsertCategoryTemplate(category: canonicalCategory, fields: updatedFields)
        recordCategoryMutation(canonicalCategory, isDeleted: false, updatedAt: Date())
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Category updated."
        return true
    }

    func categoryTemplateReferencedTargetFieldIDs(_ category: String) -> Set<String> {
        fieldReferenceTargetFieldIDs(
            targetCategory: category,
            templates: categoryTemplates
        )
    }

    func categoryTemplateStoredValueFieldIDs(_ category: String) -> Set<String> {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let template = categoryTemplates.first(where: {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalized) == .orderedSame
        }) else {
            return []
        }
        return Set(entries.lazy
            .filter {
                !$0.isDeleted && $0.payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(normalized) == .orderedSame
            }
            .flatMap { entry in
                entry.customFields.compactMap { field -> String? in
                    guard !field.value.isEmpty,
                          let templateField = customFieldSemantics(field: field, template: template).templateField else {
                        return nil
                    }
                    return templateField.id
                }
            })
    }

    func updateEntryReference(entryID: String, fieldID: String, targetID: String) -> Bool {
        guard let entryIndex = entries.firstIndex(where: { $0.id == entryID && !$0.isDeleted }) else {
            statusMessage = "Entry not found."
            return false
        }
        let entry = entries[entryIndex]
        let template = categoryTemplates.first {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(
                    entry.payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
                ) == .orderedSame
        }
        guard let fieldIndex = entry.customFields.firstIndex(where: { $0.id == fieldID }) else {
            statusMessage = "Entry reference field not found."
            return false
        }
        let semantics = customFieldSemantics(field: entry.customFields[fieldIndex], template: template)
        guard semantics.semantic == .entryReference || semantics.semantic == .fieldReference,
              let templateField = semantics.templateField else {
            statusMessage = "Entry reference field not found."
            return false
        }
        if semantics.semantic == .fieldReference,
           !fieldReferenceTemplateConfigurationIsValid(
               sourceCategory: entry.payload.category,
               sourceField: templateField,
               templates: categoryTemplates
           ) {
            statusMessage = "Field reference configuration needs repair."
            return false
        }
        if !targetID.isEmpty {
            guard let target = entries.first(where: { $0.id == targetID && !$0.isDeleted }) else {
                statusMessage = "Entry reference target not found."
                return false
            }
            let requiredCategory = templateField.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
            let actualCategory = target.payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard requiredCategory.isEmpty
                    || actualCategory.caseInsensitiveCompare(requiredCategory) == .orderedSame else {
                statusMessage = "Entry reference target is outside the required category."
                return false
            }
        }

        let now = Date()
        entries[entryIndex].customFields[fieldIndex].value = targetID
        entries[entryIndex].updatedAt = now
        entries[entryIndex].markLocalEntryChange(deviceId: syncSettings.deviceId, updatedAt: now)
        rebuildCollections()
        persistUnlockedSnapshot()
        statusMessage = "Entry reference updated."
        return true
    }

    func liveEntry(id: String) -> VaultEntry? {
        entries.first { $0.id == id && !$0.isDeleted }
    }

    private func appendTemplateField(
        _ field: FieldTemplate,
        to fields: inout [FieldTemplate],
        includedIDs: inout Set<String>,
        includedNames: inout Set<String>
    ) {
        let nameKey = field.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !nameKey.isEmpty,
              includedIDs.insert(field.id).inserted,
              includedNames.insert(nameKey).inserted else {
            return
        }
        fields.append(field)
    }

    func deleteCategory(_ category: String) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Value is required."
            return false
        }

        var changed = removeTaxonomyValue(normalized, from: &manualCategories)
        if removeCategoryTemplate(normalized) {
            changed = true
        }
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
        recordCategoryMutation(normalized, isDeleted: true, updatedAt: Date())
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

        let now = Date()
        for category in categories {
            recordCategoryMutation(category, isDeleted: true, updatedAt: now)
        }
        entries = []
        manualCategories = []
        categoryTemplates = []
        manualTags = []
        categories = []
        tags = []
        requireTotp = false
        totpSecret = ""
        lastBackupStatus = "No backup has run"
        do {
            try recordLocalMutationForSync()
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
            try recordLocalMutationForSync()
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
        let currentEntry = entries.first { $0.id == entry.id && !$0.isDeleted } ?? entry
        do {
            let exportURL = try repository.saveEntryExport(currentEntry, categoryTemplates: categoryTemplates)
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
        let currentEntry = entries.first { $0.id == entry.id && !$0.isDeleted } ?? entry
        do {
            let export = try repository.makeEntryExport(
                currentEntry,
                selectedFieldIDs: selectedFieldIDs,
                categoryTemplates: categoryTemplates
            )
            statusMessage = "Entry export ready: \(export.fileName)"
            return export
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func makeSelectedEntryTextExport(
        _ entry: VaultEntry,
        selectedFieldIDs: Set<String>
    ) -> VaultExportFile? {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return nil
        }
        let currentEntry = entries.first { $0.id == entry.id && !$0.isDeleted } ?? entry
        let export = repository.makeSelectedEntryTextExport(
            currentEntry,
            selectedFieldIDs: selectedFieldIDs,
            categoryTemplates: categoryTemplates,
            entries: entries
        )
        statusMessage = "Entry export ready: \(export.fileName)"
        return export
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

    func makeCategoryExport(_ category: String) -> VaultExportFile? {
        guard isUnlocked else {
            statusMessage = "Unlock the vault before exporting."
            return nil
        }
        do {
            let exportedEntries = entries
                .filter { !$0.isDeleted && $0.payload.category == category }
                .sorted { $0.label < $1.label }
            let export = try repository.makeCategoryExport(
                category: category,
                entries: exportedEntries,
                categoryTemplates: categoryTemplates
            )
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
                let flutterDecoder = FlutterSyncPayloadDecoder(
                    masterPassword: masterPassword,
                    crypto: crypto
                )
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
                    remotePayloadDecoder: flutterDecoder.decode,
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

    private func recordLocalMutationForSync() throws {
        localChangeRevision += 1
        if isSyncing {
            syncRequestedAgain = true
        }
        try markLocalChangesForSync()
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
                query.isEmpty || entry.withFieldReferenceSearchProjection(
                    categoryTemplates: categoryTemplates,
                    entries: entries
                ).matchesSearchQuery(query)
            }
            .sorted { left, right in
                left.updatedAt == right.updatedAt ? left.id < right.id : left.updatedAt > right.updatedAt
            }
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
        let deletedCategoryKeys = Set(categoryStates.values.compactMap { state in
            state.isDeleted ? state.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
        })
        let activeStateCategories = categoryStates.values.compactMap { state in
            state.isDeleted ? nil : state.name
        }
        categories = normalizedTaxonomyValues(
            Array(manualCategories) + activeStateCategories + activeEntries.map(\.payload.category)
        ).filter { !deletedCategoryKeys.contains($0.lowercased()) }
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
            categoryTemplates = []
            categoryStates = [:]
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
        loadCategoryStates(from: snapshot)
        categoryTemplates = normalizedCategoryTemplates(snapshot.categoryTemplates, categories: snapshot.categories)
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
            loadCategoryStates(from: snapshot)
            categoryTemplates = normalizedCategoryTemplates(snapshot.categoryTemplates, categories: snapshot.categories)
            manualTags = Set(normalizedTaxonomyValues(snapshot.tags))
            requireTotp = snapshot.security.requireTotp
            totpSecret = snapshot.security.totpSecret
            syncStatus = snapshot.syncStatus
            lastBackupStatus = snapshot.lastBackupStatus
            rebuildCollections()
        } else {
            entries = []
            categories = []
            categoryTemplates = []
            tags = []
            manualCategories = []
            categoryStates = [:]
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
        if !hasSameSyncBusinessContent(currentSnapshot(), result.snapshot) {
            entries = result.snapshot.entries
            manualCategories = Set(normalizedTaxonomyValues(result.snapshot.categories))
            loadCategoryStates(from: result.snapshot)
            categoryTemplates = normalizedCategoryTemplates(
                result.snapshot.categoryTemplates,
                categories: result.snapshot.categories
            )
            manualTags = Set(normalizedTaxonomyValues(result.snapshot.tags))
            requireTotp = result.snapshot.security.requireTotp
            totpSecret = result.snapshot.security.totpSecret
            lastBackupStatus = result.snapshot.lastBackupStatus
            rebuildCollections()
        }
        syncSettings = result.settings
        syncSettings.hasLocalChanges = false
        syncStatus = result.settings.lastSyncMessage ?? "Sync complete."
        statusMessage = syncStatus
        try syncSettingsRepository?.save(syncSettings)
        try saveSnapshot()
    }

    private func hasSameSyncBusinessContent(_ left: VaultSnapshot, _ right: VaultSnapshot) -> Bool {
        left.entries.sorted { $0.id < $1.id } == right.entries.sorted { $0.id < $1.id }
            && left.categories.sorted() == right.categories.sorted()
            && left.categoryTemplates.sorted {
                $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
            } == right.categoryTemplates.sorted {
                $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
            }
            && left.categoryStates.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            } == right.categoryStates.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            && left.tags.sorted() == right.tags.sorted()
            && left.security == right.security
    }

    private func applyImportedSnapshot(_ snapshot: VaultSnapshot) throws {
        entries = snapshot.entries
        manualCategories = Set(normalizedTaxonomyValues(snapshot.categories))
        loadCategoryStates(from: snapshot)
        categoryTemplates = normalizedCategoryTemplates(snapshot.categoryTemplates, categories: snapshot.categories)
        manualTags = Set(normalizedTaxonomyValues(snapshot.tags))
        requireTotp = snapshot.security.requireTotp
        totpSecret = snapshot.security.totpSecret
        syncStatus = snapshot.syncStatus
        lastBackupStatus = snapshot.lastBackupStatus
        rebuildCollections()
        try recordLocalMutationForSync()
        try saveSnapshot()
    }

    private func applyScopedExport(
        _ scopedExport: ScopedVaultExport,
        strategy: ImportConflictStrategy
    ) throws -> (created: Int, updated: Int, skipped: Int) {
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

    private func normalizedCategoryTemplates(
        _ templates: [CategoryTemplate],
        categories: [String]
    ) -> [CategoryTemplate] {
        let normalizedCategories = normalizedTaxonomyValues(categories)
        let templatesByCategory: [String: CategoryTemplate] = Dictionary(uniqueKeysWithValues: templates.compactMap { template -> (String, CategoryTemplate)? in
            let category = template.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { return nil }
            return (category.lowercased(), CategoryTemplate(category: category, fields: template.fields))
        })
        return normalizedCategories.map { category in
            templatesByCategory[category.lowercased()] ?? CategoryTemplate(category: category)
        }
    }

    private func upsertCategoryTemplate(category: String, fields: [FieldTemplate]) {
        if let index = categoryTemplates.firstIndex(where: { $0.category.caseInsensitiveEquals(category) }) {
            categoryTemplates[index] = CategoryTemplate(category: category, fields: fields)
        } else {
            categoryTemplates.append(CategoryTemplate(category: category, fields: fields))
        }
    }

    private func mergeImportedCategoryTemplates(_ importedTemplates: [CategoryTemplate]) -> Bool {
        var changed = false
        for importedTemplate in importedTemplates {
            let importedCategory = importedTemplate.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !importedCategory.isEmpty else { continue }
            var templateChanged = false
            if !manualCategories.contains(where: { $0.caseInsensitiveEquals(importedCategory) }) {
                manualCategories.insert(importedCategory)
                changed = true
            }
            ensureCategoryIsActive(importedCategory, updatedAt: Date())
            if let templateIndex = categoryTemplates.firstIndex(where: {
                $0.category.caseInsensitiveEquals(importedCategory)
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
        categoryTemplates.sort {
            $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
        }
        return changed
    }

    private func renameCategoryTemplate(oldValue: String, to newValue: String) {
        if let index = categoryTemplates.firstIndex(where: { $0.category.caseInsensitiveEquals(oldValue) }) {
            categoryTemplates[index].category = newValue
        } else {
            categoryTemplates.append(CategoryTemplate(category: newValue))
        }
    }

    @discardableResult
    private func removeCategoryTemplate(_ category: String) -> Bool {
        let before = categoryTemplates.count
        categoryTemplates.removeAll { $0.category.caseInsensitiveEquals(category) }
        return categoryTemplates.count != before
    }

    @discardableResult
    private func removeTaxonomyValue(_ value: String, from target: inout Set<String>) -> Bool {
        let matches = target.filter { $0.caseInsensitiveEquals(value) }
        for match in matches {
            target.remove(match)
        }
        return !matches.isEmpty
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
        let updater = syncSettings.deviceId.isEmpty ? "macos-native" : syncSettings.deviceId
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

private struct DraftCustomFieldState: Equatable {
    var field: CustomField
    var sourceCategory: String
    var isProtected: Bool
    var mustPreserveOriginal: Bool
}

struct EntryDraft: Equatable {
    var label = ""
    private var payloadKind: VaultEntryType = .credential
    var credential = CredentialPayload()
    var server = ServerPayload()
    var service = ServicePayload()
    private var customFieldStates: [DraftCustomFieldState] = []

    var customFields: [CustomField] {
        get { customFieldStates.map(\.field) }
        set {
            let existingById = Dictionary(
                customFieldStates.map { ($0.field.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            customFieldStates = newValue.map { field in
                guard var existing = existingById[field.id] else {
                    return DraftCustomFieldState(
                        field: field,
                        sourceCategory: category.trimmingCharacters(in: .whitespacesAndNewlines),
                        isProtected: false,
                        mustPreserveOriginal: false
                    )
                }
                existing.field = field
                return existing
            }
        }
    }

    var protectedCustomFieldIds: Set<String> {
        Set(customFieldStates.lazy.filter(\.isProtected).map { $0.field.id })
    }

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
        customFieldStates.compactMap { state in
            if state.isProtected {
                return state.mustPreserveOriginal ? state.field : nil
            }
            let field = state.field
            let normalized = CustomField(
                id: field.id,
                templateFieldId: field.templateFieldId,
                name: field.name.trimmingCharacters(in: .whitespacesAndNewlines),
                value: field.value
            )
            return normalized.name.isEmpty && normalized.value.isEmpty && normalized.templateFieldId.isEmpty
                ? nil
                : normalized
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
        customFieldStates = entry.customFields.map {
            DraftCustomFieldState(
                field: $0,
                sourceCategory: category.trimmingCharacters(in: .whitespacesAndNewlines),
                isProtected: false,
                mustPreserveOriginal: false
            )
        }
    }

    mutating func applyTemplateFields(_ fields: [FieldTemplate]) {
        for templateField in fields {
            let name = templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let existingIndex = customFieldStates.firstIndex(where: {
                $0.field.matches(templateField: templateField)
            }) {
                if templateField.normalizedValueType != "text" {
                    customFieldStates[existingIndex].isProtected = true
                    customFieldStates[existingIndex].mustPreserveOriginal = true
                }
                continue
            }
            guard templateField.normalizedValueType == "text" else { continue }
            customFieldStates.append(DraftCustomFieldState(
                field: CustomField(templateFieldId: templateField.id, name: name),
                sourceCategory: category.trimmingCharacters(in: .whitespacesAndNewlines),
                isProtected: false,
                mustPreserveOriginal: false
            ))
        }
    }

    mutating func configureTemplateFields(_ fields: [FieldTemplate]) {
        let targetCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = CategoryTemplate(category: targetCategory, fields: fields)
        var usedStateIndexes = Set<Int>()
        var seenNames = Set<String>()
        var nextStates: [DraftCustomFieldState] = []

        for templateField in fields {
            guard templateField.normalizedValueType == "text"
                    || templateField.normalizedValueType == "entryReference"
                    || templateField.normalizedValueType == "fieldReference" else {
                continue
            }
            let name = templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameKey = name.lowercased()
            guard !name.isEmpty,
                  !name.caseInsensitiveEquals("名称"),
                  seenNames.insert(nameKey).inserted else {
                continue
            }
            let existingIndex = customFieldStates.indices.first { index in
                !usedStateIndexes.contains(index)
                    && customFieldStates[index].sourceCategory.caseInsensitiveEquals(targetCategory)
                    && customFieldStates[index].field.matches(templateField: templateField)
            }
            let existing = existingIndex.map { customFieldStates[$0] }
            if let existingIndex { usedStateIndexes.insert(existingIndex) }
            nextStates.append(DraftCustomFieldState(
                field: CustomField(
                    id: existing?.field.id ?? UUID().uuidString.lowercased(),
                    templateFieldId: templateField.id,
                    name: name,
                    value: existing?.field.value ?? ""
                ),
                sourceCategory: targetCategory,
                isProtected: false,
                mustPreserveOriginal: false
            ))
        }

        for index in customFieldStates.indices where !usedStateIndexes.contains(index) {
            var state = customFieldStates[index]
            let belongsToTarget = state.sourceCategory.caseInsensitiveEquals(targetCategory)
            if !belongsToTarget {
                state.isProtected = true
                nextStates.append(state)
                continue
            }
            switch customFieldSemantics(field: state.field, template: template).semantic {
            case .text:
                state.isProtected = false
            case .entryReference, .fieldReference, .unsupported:
                state.isProtected = true
                state.mustPreserveOriginal = true
            }
            nextStates.append(state)
        }
        customFieldStates = nextStates
    }

    mutating func protectUnsupportedCustomFields(template: CategoryTemplate?) {
        for index in customFieldStates.indices {
            guard customFieldStates[index].sourceCategory.caseInsensitiveEquals(category) else {
                customFieldStates[index].isProtected = true
                continue
            }
            if customFieldSemantics(field: customFieldStates[index].field, template: template).semantic == .unsupported {
                customFieldStates[index].isProtected = true
                customFieldStates[index].mustPreserveOriginal = true
            }
        }
    }

}

private extension CustomField {
    func matches(templateField: FieldTemplate) -> Bool {
        if !templateFieldId.isEmpty {
            return templateFieldId == templateField.id
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(
                templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }
}

extension VaultPayload {
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
