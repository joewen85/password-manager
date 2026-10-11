import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("Field reference UI behavior")
struct FieldReferenceUIBehaviorTests {
    @Test("Detail and search expose values only for text fields")
    func detailAndSearchExposeOnlySafeFieldValues() throws {
        let template = CategoryTemplate(category: "Servers", fields: [
            FieldTemplate(id: "notes", name: "Notes"),
            FieldTemplate(id: "owner", name: "Owner", valueType: "entryReference", targetCategory: "Accounts"),
            FieldTemplate(id: "future", name: "Future", valueType: "future-v3")
        ])
        let target = entry(id: "target:opaque-id", label: "Primary Account", category: "Accounts")
        let fields = [
            CustomField(id: "text", templateFieldId: "notes", name: "Notes", value: "public note"),
            CustomField(id: "reference", templateFieldId: "owner", name: "Owner", value: target.id),
            CustomField(id: "unknown", templateFieldId: "future", name: "Future", value: "unknown-secret"),
            CustomField(id: "orphan", templateFieldId: "missing", name: "Notes", value: "orphan-secret"),
            CustomField(id: "legacy", name: "Region", value: "legacy-visible")
        ]
        let source = entry(id: "source", label: "Server", category: "Servers", customFields: fields)

        #expect(exposedCustomFieldValue(field: fields[0], template: template) == "public note")
        #expect(exposedCustomFieldValue(field: fields[1], template: template) == nil)
        #expect(exposedCustomFieldValue(field: fields[2], template: template) == nil)
        #expect(exposedCustomFieldValue(field: fields[3], template: template) == nil)
        #expect(exposedCustomFieldValue(field: fields[4], template: template) == "legacy-visible")

        let projected = source.withEntryReferenceSearchProjection(template: template, entries: [target, source])
        let values = Dictionary(uniqueKeysWithValues: projected.customFields.map { ($0.id, $0.value) })
        #expect(values["text"] == "public note")
        #expect(values["reference"] == "Primary Account Accounts")
        #expect(values["unknown"] == "")
        #expect(values["orphan"] == "")
        #expect(values["legacy"] == "legacy-visible")
        for forbidden in [target.id, "unknown-secret", "orphan-secret"] {
            #expect(!projected.customFields.map(\.value).joined(separator: " ").contains(forbidden))
        }
    }

    @Test("Five reference states never present the opaque target ID")
    func fiveReferenceStatesHaveSafePresentation() {
        let opaqueID = "opaque:target:must-not-render"
        let target = EntryReferenceTarget(id: opaqueID, label: "Primary", category: "Accounts")
        let presentations = [
            entryReferenceStatusText(EntryReferenceResolution(status: .empty)),
            entryReferenceStatusText(EntryReferenceResolution(status: .resolved, target: target)),
            entryReferenceStatusText(EntryReferenceResolution(status: .missing)),
            entryReferenceStatusText(EntryReferenceResolution(status: .deleted, target: target)),
            entryReferenceStatusText(EntryReferenceResolution(status: .categoryMismatch, target: target))
        ]

        #expect(presentations[0] == L10n.t("No entry selected."))
        #expect(presentations[1].contains("Primary"))
        #expect(presentations[1].contains("Accounts"))
        #expect(presentations[2] == L10n.t("Referenced entry is unavailable."))
        #expect(presentations[3] == L10n.t("Referenced entry was deleted."))
        #expect(presentations[4] == L10n.t("Referenced entry is outside the target category."))
        #expect(presentations.allSatisfy { !$0.contains(opaqueID) })
    }

    @Test("Candidates are live, category scoped, and searchable only by label or category")
    func candidatesUseSafeProjection() {
        let entries = [
            entry(id: "a", label: "Alpha", category: " Accounts ", secret: "alpha-secret"),
            entry(id: "b", label: "Beta", category: "accounts"),
            entry(id: "server", label: "Gateway", category: "Servers"),
            entry(id: "deleted", label: "Deleted", category: "Accounts", isDeleted: true)
        ]

        #expect(entryReferenceCandidates(entries: entries, targetCategory: " accounts ").map(\.id) == ["a", "b"])
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "Accounts", query: "beta").map(\.id) == ["b"])
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "", query: "Servers").map(\.id) == ["server"])
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "", query: "alpha-secret").isEmpty)
        #expect(entryReferenceCandidates(entries: entries, targetCategory: "", query: "a").first == EntryReferenceCandidate(
            id: "a",
            label: "Alpha",
            category: "Accounts"
        ))
    }

    @Test("A to B to A keeps category-owned values separate when legacy template IDs match")
    func categorySwitchKeepsSharedLegacyIDsSeparate() throws {
        let templateA = sharedTemplate(category: "A")
        let templateB = sharedTemplate(category: "B")
        var draft = EntryDraft(category: "A", templateFields: templateA.fields)
        setValue("A note", templateID: "legacy-notes", in: &draft)
        setValue("A-target ", templateID: "legacy-owner", in: &draft)
        let aInstanceIDs = activeFields(draft).map(\.id)

        draft.configureTemplateFields(templateA.fields)
        #expect(activeFields(draft).map(\.value) == ["A note", "A-target "])

        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        #expect(activeFields(draft).map(\.value) == ["", ""])
        #expect(activeFields(draft).map(\.id).allSatisfy { !aInstanceIDs.contains($0) })
        setValue("B note", templateID: "legacy-notes", in: &draft)
        setValue("B-target ", templateID: "legacy-owner", in: &draft)

        draft.category = "A"
        draft.configureTemplateFields(templateA.fields)
        #expect(activeFields(draft).map(\.value) == ["A note", "A-target "])

        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        #expect(activeFields(draft).map(\.value) == ["B note", "B-target "])
        #expect(draft.normalizedCustomFields.map(\.value) == ["B note", "B-target "])
    }

    @MainActor
    @Test("Saving B and reopening preserves B without inheriting A shared-ID values")
    func savedCategorySwitchReopensWithoutValueBleed() throws {
        let directory = temporaryDirectory("SavedCategorySwitch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        let templateA = sharedTemplate(category: "A", includeUnknown: true)
        let templateB = sharedTemplate(category: "B", includeUnknown: true)
        let original = entry(
            id: "source",
            label: "Source",
            category: "A",
            customFields: [
                CustomField(id: "a-note", templateFieldId: "legacy-notes", name: "Notes", value: "A note"),
                CustomField(id: "a-owner", templateFieldId: "legacy-owner", name: "Owner", value: "A-target"),
                CustomField(id: "unknown", templateFieldId: "future", name: "Future", value: "opaque-unknown"),
                CustomField(id: "orphan", templateFieldId: "missing", name: "Orphan", value: "opaque-orphan")
            ]
        )
        try importSnapshot(
            VaultSnapshot(
                entries: [original],
                categories: ["A", "B"],
                categoryTemplates: [templateA, templateB]
            ),
            into: store,
            repository: repository,
            directory: directory
        )

        var draft = EntryDraft(entry: original)
        draft.configureTemplateFields(templateA.fields)
        draft.category = "B"
        draft.configureTemplateFields(templateB.fields)
        setValue("B note", templateID: "legacy-notes", in: &draft)
        setValue("B-target ", templateID: "legacy-owner", in: &draft)
        store.upsert(draft, editing: original)

        let reloadedStore = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(reloadedStore.unlock(password: "test-password"))
        let saved = try #require(reloadedStore.entries.first { $0.id == original.id })
        #expect(saved.payload.category == "B")
        #expect(saved.customFields.contains { $0.value == "A note" } == false)
        #expect(saved.customFields.contains { $0.value == "A-target" } == false)
        #expect(saved.customFields.contains { $0.value == "opaque-unknown" })
        #expect(saved.customFields.contains { $0.value == "opaque-orphan" })

        var reopened = EntryDraft(entry: saved)
        reopened.configureTemplateFields(templateB.fields)
        #expect(activeFields(reopened).map(\.value).prefix(2) == ["B note", "B-target "])
        reopened.category = "A"
        reopened.configureTemplateFields(templateA.fields)
        #expect(activeFields(reopened).map(\.value).prefix(2) == ["", ""])
        reopened.category = "B"
        reopened.configureTemplateFields(templateB.fields)
        #expect(activeFields(reopened).map(\.value).prefix(2) == ["B note", "B-target "])
    }

    @MainActor
    @Test("Store validates live category-scoped targets and preserves opaque IDs exactly")
    func storeValidatesTargetsAndPreservesOpaqueIDs() throws {
        let directory = temporaryDirectory("ReferenceUpdate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        let template = CategoryTemplate(category: "Servers", fields: [
            FieldTemplate(id: "owner", name: "Owner", valueType: "entryReference", targetCategory: "Accounts")
        ])
        let source = entry(
            id: "source",
            label: "Source",
            category: "Servers",
            customFields: [CustomField(id: "owner-field", templateFieldId: "owner", name: "Owner")]
        )
        let exactTarget = entry(id: "opaque-target ", label: "Exact", category: " Accounts ")
        let wrongCategory = entry(id: "wrong", label: "Wrong", category: "Archive")
        let deleted = entry(id: "deleted", label: "Deleted", category: "Accounts", isDeleted: true)
        try importSnapshot(
            VaultSnapshot(
                entries: [source, exactTarget, wrongCategory, deleted],
                categories: ["Servers", "Accounts", "Archive"],
                categoryTemplates: [template]
            ),
            into: store,
            repository: repository,
            directory: directory
        )

        #expect(!store.updateEntryReference(entryID: source.id, fieldID: "owner-field", targetID: "opaque-target"))
        #expect(!store.updateEntryReference(entryID: source.id, fieldID: "owner-field", targetID: wrongCategory.id))
        #expect(!store.updateEntryReference(entryID: source.id, fieldID: "owner-field", targetID: deleted.id))
        #expect(!store.updateEntryReference(entryID: source.id, fieldID: "owner-field", targetID: "missing"))
        #expect(store.updateEntryReference(entryID: source.id, fieldID: "owner-field", targetID: exactTarget.id))
        #expect(store.entries.first { $0.id == source.id }?.customFields.first?.value == "opaque-target ")
        #expect(store.updateEntryReference(entryID: source.id, fieldID: "owner-field", targetID: ""))
        #expect(store.entries.first { $0.id == source.id }?.customFields.first?.value == "")
    }

    @MainActor
    @Test("Legacy reference templates stay read-only with or without stored values")
    func storedValueTemplateSafetyIsCategoryScoped() throws {
        let directory = temporaryDirectory("TemplateSafety")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        let locked = FieldTemplate(id: "shared-legacy", name: "Owner", valueType: "entryReference", targetCategory: "Accounts")
        let unknown = FieldTemplate(id: "future", name: "Future", valueType: "future-v3", targetCategory: "Targets")
        let source = entry(
            id: "source",
            label: "Source",
            category: "A",
            customFields: [CustomField(id: "owner", templateFieldId: locked.id, name: locked.name, value: "target")]
        )
        let deletedSource = entry(
            id: "deleted-source",
            label: "Deleted Source",
            category: "A",
            customFields: [CustomField(id: "deleted-owner", templateFieldId: locked.id, name: locked.name, value: "target")],
            isDeleted: true
        )
        let movedSource = entry(
            id: "moved-source",
            label: "Moved Source",
            category: "B",
            customFields: [CustomField(id: "moved-owner", templateFieldId: locked.id, name: locked.name, value: "target")]
        )
        try importSnapshot(
            VaultSnapshot(
                entries: [source, deletedSource, movedSource],
                categories: ["A", "B", "Accounts", "People"],
                categoryTemplates: [
                    CategoryTemplate(category: "A", fields: [locked, unknown]),
                    CategoryTemplate(category: "B", fields: [locked])
                ]
            ),
            into: store,
            repository: repository,
            directory: directory
        )

        #expect(store.categoryTemplateStoredValueFieldIDs(" a ") == [locked.id])
        #expect(store.categoryTemplateStoredValueFieldIDs("B") == [locked.id])
        store.delete(source)
        #expect(store.categoryTemplateStoredValueFieldIDs("A").isEmpty)
        #expect(store.updateCategoryTemplate("A", fields: [
            FieldTemplate(id: locked.id, name: "Primary Owner", valueType: "text", targetCategory: "People")
        ]))
        var aTemplate = try #require(store.categoryTemplates.first { $0.category == "A" })
        var savedLocked = try #require(aTemplate.fields.first { $0.id == locked.id })
        #expect(savedLocked.name == "Owner")
        #expect(savedLocked.valueType == "entryReference")
        #expect(savedLocked.targetCategory == "Accounts")
        #expect(aTemplate.fields.contains(unknown))

        #expect(store.updateCategoryTemplate("A", fields: []))
        aTemplate = try #require(store.categoryTemplates.first { $0.category == "A" })
        savedLocked = try #require(aTemplate.fields.first { $0.id == locked.id })
        #expect(savedLocked.valueType == "entryReference")
        #expect(aTemplate.fields.contains(unknown))

        #expect(store.updateCategoryTemplate("B", fields: [
            FieldTemplate(id: locked.id, name: "Owner Text", valueType: "text")
        ]))
        let bField = try #require(store.categoryTemplates.first { $0.category == "B" }?.fields.first { $0.id == locked.id })
        #expect(bField == locked)
    }

    private func activeFields(_ draft: EntryDraft) -> [CustomField] {
        draft.customFields.filter { !draft.protectedCustomFieldIds.contains($0.id) }
    }

    private func setValue(_ value: String, templateID: String, in draft: inout EntryDraft) {
        guard let index = draft.customFields.firstIndex(where: {
            $0.templateFieldId == templateID && !draft.protectedCustomFieldIds.contains($0.id)
        }) else {
            Issue.record("Missing active field \(templateID)")
            return
        }
        draft.customFields[index].value = value
    }

    private func sharedTemplate(category: String, includeUnknown: Bool = false) -> CategoryTemplate {
        var fields = [
            FieldTemplate(id: "legacy-notes", name: "Notes"),
            FieldTemplate(id: "legacy-owner", name: "Owner", valueType: "entryReference", targetCategory: "Targets")
        ]
        if includeUnknown {
            fields.append(FieldTemplate(id: "future", name: "Future", valueType: "future-v3"))
        }
        return CategoryTemplate(category: category, fields: fields)
    }

    @MainActor
    private func importSnapshot(
        _ snapshot: VaultSnapshot,
        into store: VaultStore,
        repository: FileVaultRepository,
        directory: URL
    ) throws {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try repository.encodeSnapshot(snapshot).write(to: url)
        store.importSnapshot(from: url)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOS\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(
        id: String,
        label: String,
        category: String,
        secret: String = "private-secret",
        customFields: [CustomField] = [],
        isDeleted: Bool = false
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            label: label,
            type: .credential,
            payload: .credential(CredentialPayload(
                username: "private-user",
                password: secret,
                token: "private-token",
                secretKey: "private-key",
                category: category
            )),
            customFields: customFields,
            isDeleted: isDeleted
        )
    }
}
