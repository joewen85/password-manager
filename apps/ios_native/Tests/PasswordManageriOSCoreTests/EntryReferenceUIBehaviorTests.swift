import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("Entry reference UI behavior")
struct EntryReferenceUIBehaviorTests {
    @Test("Safe search projection hides raw reference, unknown, and orphan values")
    func safeSearchProjectionHidesOpaqueValues() {
        let template = CategoryTemplate(category: "Servers", fields: [
            FieldTemplate(id: "notes", name: "Notes"),
            FieldTemplate(
                id: "owner",
                name: "Owner",
                valueType: "entryReference",
                targetCategory: "Accounts"
            ),
            FieldTemplate(id: "future", name: "Future", valueType: "futureRelationV3")
        ])
        let target = entry(
            id: "RAW-TARGET-ID",
            label: "Primary Account",
            category: "Accounts",
            secret: "target-secret"
        )
        let source = entry(
            id: "source",
            label: "Server",
            category: "Servers",
            customFields: [
                CustomField(id: "text", templateFieldId: "notes", name: "Notes", value: "public-note"),
                CustomField(id: "reference", templateFieldId: "owner", name: "Owner", value: target.id),
                CustomField(id: "unknown", templateFieldId: "future", name: "Future", value: "unknown-secret"),
                CustomField(id: "orphan", templateFieldId: "missing", name: "Orphan", value: "orphan-secret"),
                CustomField(id: "legacy", name: "Region", value: "legacy-visible")
            ]
        )

        let projected = source.withEntryReferenceSearchProjection(template: template, entries: [target, source])
        let values = Dictionary(uniqueKeysWithValues: projected.customFields.map { ($0.id, $0.value) })

        #expect(values["text"] == "public-note")
        #expect(values["reference"] == "Primary Account Accounts")
        #expect(values["unknown"] == "")
        #expect(values["orphan"] == "")
        #expect(values["legacy"] == "legacy-visible")
        let searchable = projected.customFields.map(\.value).joined(separator: " ")
        for forbidden in [target.id, "target-secret", "unknown-secret", "orphan-secret"] {
            #expect(!searchable.contains(forbidden))
        }
    }

    @Test("Reference candidates are live, category scoped, and search only safe projection fields")
    func candidatesUseOnlyLabelAndCategory() {
        let alpha = entry(
            id: "account-a",
            label: "Alpha Account",
            category: " Accounts ",
            secret: "alpha-private-secret",
            customFields: [CustomField(name: "Hidden", value: "hidden-custom-secret")]
        )
        let beta = entry(id: "account-b", label: "Beta Account", category: "accounts")
        let other = entry(id: "server", label: "Gateway", category: "Servers")
        let deleted = entry(id: "deleted", label: "Deleted Account", category: "Accounts", isDeleted: true)
        let entries = [other, beta, deleted, alpha]

        #expect(entryReferenceCandidates(entries: entries, targetCategory: " accounts ").map(\.id) == [
            "account-a", "account-b"
        ])
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "ACCOUNTS", query: "beta").map(\.id) == [
            "account-b"
        ])
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "", query: "accounts").map(\.id) == [
            "account-a", "account-b"
        ])
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "", query: "alpha-private-secret").isEmpty)
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "", query: "hidden-custom-secret").isEmpty)
    }

    @Test("Template save protects stored and unknown fields while allowing safe edits")
    func templateSaveProtection() throws {
        let storedText = FieldTemplate(id: "stored-text", name: "Notes")
        let storedReference = FieldTemplate(
            id: "stored-reference",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let unknown = FieldTemplate(
            id: "future",
            name: "Future",
            valueType: "futureRelationV3",
            targetCategory: "  Future Targets  "
        )

        let deletionAttempt = categoryTemplateFieldsForUserSave(
            existing: [storedText, storedReference, unknown],
            requestedCustomFields: [],
            storedValueFieldIds: [storedText.id, storedReference.id]
        )
        #expect(deletionAttempt.contains(storedText))
        #expect(deletionAttempt.contains(storedReference))
        #expect(deletionAttempt.contains(unknown))

        let edited = categoryTemplateFieldsForUserSave(
            existing: [storedText, storedReference, unknown],
            requestedCustomFields: [
                storedText.copy(name: "Renamed Notes", valueType: "entryReference", targetCategory: "Accounts"),
                storedReference.copy(name: "Primary Owner", valueType: "entryReference", targetCategory: " Identity "),
                unknown.copy(name: "Changed", valueType: "text", targetCategory: "")
            ],
            storedValueFieldIds: [storedText.id, storedReference.id]
        )
        #expect(edited.first { $0.id == storedText.id } == storedText)
        #expect(edited.first { $0.id == storedReference.id } == storedReference)
        #expect(edited.first { $0.id == unknown.id } == unknown)

        let created = newCategoryTemplateField(
            name: " Owner ",
            valueType: "fieldReference",
            targetCategory: " Accounts ",
            targetFieldId: "login"
        )
        #expect(created.name == "Owner")
        #expect(created.targetCategory == "Accounts")
        #expect(created.targetFieldId == "login")
        #expect(created.id.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil)
    }

    @Test("Draft preserves opaque values and hides unknown and orphan bindings on first open")
    func draftPreservesOpaqueAndUnsupportedValues() throws {
        let reference = FieldTemplate(
            id: "owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let unknown = FieldTemplate(id: "future", name: "Future", valueType: "futureRelationV3")
        let template = CategoryTemplate(category: "Servers", fields: [
            FieldTemplate(id: "notes", name: "Notes"), reference, unknown
        ])
        let referenceField = CustomField(
            id: "reference-field",
            templateFieldId: reference.id,
            name: "Owner",
            value: " opaque-target-id "
        )
        let unknownField = CustomField(
            id: "unknown-field",
            templateFieldId: unknown.id,
            name: "Future",
            value: " unknown-value "
        )
        let orphanField = CustomField(
            id: "orphan-field",
            templateFieldId: "missing",
            name: "Orphan",
            value: " orphan-value "
        )
        let textField = CustomField(
            id: "text-field",
            templateFieldId: "notes",
            name: "Notes",
            value: " text value "
        )
        var draft = EntryDraft(entry: entry(
            id: "source",
            label: "Server",
            category: "Servers",
            customFields: [referenceField, unknownField, orphanField, textField]
        ))

        draft.configureTemplateFields(template.fields)

        #expect(draft.hiddenCustomFieldIds == [unknownField.id, orphanField.id])
        #expect(draft.protectedCustomFieldIds.isSuperset(of: [referenceField.id, unknownField.id, orphanField.id]))
        #expect(draft.normalizedCustomFields.first { $0.id == referenceField.id }?.value == " opaque-target-id ")
        #expect(draft.normalizedCustomFields.first { $0.id == unknownField.id } == unknownField)
        #expect(draft.normalizedCustomFields.first { $0.id == orphanField.id } == orphanField)
        #expect(draft.normalizedCustomFields.first { $0.id == textField.id }?.value == "text value")
    }

    @Test("Saving a draft drops inactive shared legacy bindings")
    func savedDraftDropsInactiveSharedLegacyBindings() throws {
        let sharedID = "legacy-shared-reference"
        let templateA = CategoryTemplate(category: "A", fields: [FieldTemplate(
            id: sharedID,
            name: "A Owner",
            valueType: "entryReference",
            targetCategory: "A"
        )])
        let templateB = CategoryTemplate(category: "B", fields: [FieldTemplate(
            id: sharedID,
            name: "B Owner",
            valueType: "entryReference",
            targetCategory: "A"
        )])

        var draft = EntryDraft(category: "A", templateFields: templateA.fields)
        let aID = try #require(draft.customFields.first?.id)
        draft.customFields[0].value = " opaque-a-target "
        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        let bIndex = try #require(draft.customFields.firstIndex { $0.name == "B Owner" })
        let bID = draft.customFields[bIndex].id
        draft.customFields[bIndex].value = " opaque-b-target "
        #expect(aID != bID)
        #expect(draft.hiddenCustomFieldIds == [aID])

        let savedFields = draft.normalizedCustomFields
        #expect(savedFields.map(\.id) == [bID])
        #expect(!savedFields.contains { $0.id == aID })
        let saved = entry(
            id: "source",
            label: "Source",
            category: "B",
            customFields: savedFields
        )
        var reopened = EntryDraft(entry: saved)
        reopened.configureTemplateFields(templateB.fields)
        #expect(reopened.customFields.first { $0.id == bID }?.value == " opaque-b-target ")
        #expect(reopened.hiddenCustomFieldIds.isEmpty)
        #expect(!reopened.customFields.contains { $0.id == aID })
    }

    @Test("Ad-hoc fields remain scoped to the category where they were added")
    func adHocFieldsRemainCategoryScoped() throws {
        let templateB = CategoryTemplate(category: "B", fields: [FieldTemplate(
            id: "template_owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )])
        let adHoc = CustomField(name: "Owner", value: "A target")
        var draft = EntryDraft(category: "A", templateFields: [])
        draft.addCustomField(adHoc)

        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        let bField = try #require(draft.customFields.first {
            $0.templateFieldId == "template_owner" && !draft.hiddenCustomFieldIds.contains($0.id)
        })
        #expect(bField.id != adHoc.id)
        #expect(bField.value.isEmpty)
        #expect(draft.hiddenCustomFieldIds.contains(adHoc.id))

        draft.category = "A"
        draft.configureTemplateFields([])
        #expect(draft.customFields.first { $0.id == adHoc.id }?.value == "A target")
        #expect(!draft.hiddenCustomFieldIds.contains(adHoc.id))
        #expect(draft.hiddenCustomFieldIds.contains(bField.id))

        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        let savedFields = draft.normalizedCustomFields
        #expect(savedFields.contains { $0.id == bField.id })
        #expect(!savedFields.contains { $0.id == adHoc.id })
    }

    @MainActor
    @Test("Entry save rejects duplicate active template bindings and keeps valid ad-hoc fields")
    func entrySaveRejectsDuplicateActiveTemplateBindings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSDuplicateEntryFieldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        #expect(store.addCategory("Servers"))
        let owner = FieldTemplate(
            id: "template_owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        #expect(store.updateCategoryTemplate(category: "Servers", requestedCustomFields: [owner]))
        let template = try #require(store.categoryTemplate(for: "Servers"))

        var duplicateDraft = EntryDraft(category: "Servers", templateFields: template.fields)
        duplicateDraft.label = "Duplicate"
        duplicateDraft.addCustomField(CustomField(name: " owner ", value: "opaque-target"))
        #expect(duplicateDraft.duplicateActiveTemplateBindingName(template: template) == "Owner")
        #expect(!store.upsert(duplicateDraft, editing: nil))
        #expect(store.statusMessage == "Field name already exists: Owner.")
        #expect(store.entries.isEmpty)

        var validDraft = EntryDraft(category: "Servers", templateFields: template.fields)
        validDraft.label = "Valid"
        validDraft.addCustomField(CustomField(name: "Region", value: "East"))
        #expect(validDraft.duplicateActiveTemplateBindingName(template: template) == nil)
        #expect(store.upsert(validDraft, editing: nil))
        let saved = try #require(store.entries.first { $0.label == "Valid" })
        #expect(saved.customFields.contains { $0.name == "Region" && $0.value == "East" })
        #expect(saved.customFields.filter { $0.name.caseInsensitiveCompare("Owner") == .orderedSame }.count == 1)
    }

    @MainActor
    @Test("Persisted same-named legacy bindings stay scoped to the saved category")
    func persistedSameNamedLegacyBindingStaysScoped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSLegacyBindingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        let sharedID = "template_owner"
        let templateA = CategoryTemplate(category: "A", fields: [FieldTemplate(
            id: sharedID,
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )])
        let templateB = CategoryTemplate(category: "B", fields: [FieldTemplate(
            id: sharedID,
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )])

        #expect(store.addCategory("B"))
        #expect(store.updateCategoryTemplate(category: "B", requestedCustomFields: templateB.fields))

        var alphaDraft = EntryDraft()
        alphaDraft.label = "Alpha Target"
        alphaDraft.category = "Accounts"
        store.upsert(alphaDraft, editing: nil)
        let alpha = try #require(store.entries.first { $0.label == alphaDraft.label })

        var betaDraft = EntryDraft()
        betaDraft.label = "Beta Target"
        betaDraft.category = "Accounts"
        store.upsert(betaDraft, editing: nil)
        let beta = try #require(store.entries.first { $0.label == betaDraft.label })

        var draft = EntryDraft(category: "A", templateFields: templateA.fields)
        draft.label = "Source Server"
        let aID = try #require(draft.customFields.first?.id)
        draft.customFields[0].value = alpha.id

        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        let bIndex = try #require(draft.customFields.firstIndex {
            $0.id != aID && !draft.hiddenCustomFieldIds.contains($0.id)
        })
        let bID = draft.customFields[bIndex].id
        #expect(draft.customFields[bIndex].value.isEmpty)
        #expect(draft.hiddenCustomFieldIds == [aID])
        draft.customFields[bIndex].value = beta.id

        draft.category = "A"
        draft.configureTemplateFields(templateA.fields)
        #expect(draft.customFields.first { $0.id == aID }?.value == alpha.id)
        #expect(draft.hiddenCustomFieldIds == [bID])

        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        #expect(draft.customFields.first { $0.id == bID }?.value == beta.id)
        #expect(draft.hiddenCustomFieldIds == [aID])

        store.upsert(draft, editing: nil)
        let saved = try #require(store.entries.first { $0.label == draft.label })
        #expect(saved.customFields.map(\.id) == [bID])
        #expect(!saved.customFields.contains { $0.id == aID })

        let resolution = try #require(store.resolveEntryReference(saved.customFields[0], sourceCategory: "B"))
        #expect(resolution.status == .resolved)
        #expect(resolution.target?.id == beta.id)
        #expect(!store.filteredEntries(searchText: alpha.label, filter: .all).contains { $0.id == saved.id })
        #expect(store.filteredEntries(searchText: beta.label, filter: .all).contains { $0.id == saved.id })
        #expect(!store.updateEntryReference(entryID: saved.id, fieldID: aID, targetID: beta.id))
        #expect(store.updateEntryReference(entryID: saved.id, fieldID: bID, targetID: beta.id))

        var reopened = EntryDraft(entry: saved)
        reopened.configureTemplateFields(templateB.fields)
        #expect(reopened.customFields.first { $0.id == bID }?.value == beta.id)
        #expect(reopened.hiddenCustomFieldIds.isEmpty)
        #expect(!reopened.customFields.contains { $0.id == aID })
    }

    @Test("Five-state presentation never exposes opaque ids")
    func fiveStatePresentationIsSafe() {
        let target = EntryReferenceTarget(id: "RAW-REFERENCE-ID", label: "Primary", category: "Accounts")
        let cases: [(EntryReferenceResolution, EntryReferencePresentation)] = [
            (.init(status: .empty), .init(text: "No entry selected.", actionTitle: "Select", isError: false, canOpenTarget: false)),
            (.init(status: .resolved, target: target), .init(text: "Primary - Accounts", actionTitle: "Replace", isError: false, canOpenTarget: true)),
            (.init(status: .missing), .init(text: "Referenced entry is missing.", actionTitle: "Repair", isError: true, canOpenTarget: false)),
            (.init(status: .deleted, target: target), .init(text: "Referenced entry was deleted.", actionTitle: "Repair", isError: true, canOpenTarget: false)),
            (.init(status: .categoryMismatch, target: target), .init(text: "Referenced entry is outside the target category.", actionTitle: "Repair", isError: true, canOpenTarget: false))
        ]

        for (resolution, expected) in cases {
            let presentation = entryReferencePresentation(resolution)
            #expect(presentation == expected)
            #expect(!presentation.text.contains(target.id))
        }
    }

    private func entry(
        id: String,
        label: String,
        category: String,
        secret: String = "secret",
        customFields: [CustomField] = [],
        isDeleted: Bool = false
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            label: label,
            type: .credential,
            payload: .credential(CredentialPayload(password: secret, category: category)),
            customFields: customFields,
            isDeleted: isDeleted
        )
    }
}

private extension FieldTemplate {
    func copy(
        name: String? = nil,
        valueType: String? = nil,
        targetCategory: String? = nil
    ) -> FieldTemplate {
        FieldTemplate(
            id: id,
            name: name ?? self.name,
            valueType: valueType ?? self.valueType,
            targetCategory: targetCategory ?? self.targetCategory
        )
    }
}
