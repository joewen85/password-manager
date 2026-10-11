import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("Entry reference resolution")
struct EntryReferenceResolutionTests {
    @Test("Exact target ID resolves to a safe display projection")
    func exactTargetIDResolvesToSafeDisplayProjection() throws {
        let target = targetEntry(
            id: "account-b",
            label: "Shared account",
            category: "Accounts",
            password: "must-not-be-projected"
        )
        let sameLabel = targetEntry(
            id: "account-a",
            label: target.label,
            category: "Accounts"
        )

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [sameLabel, target]
        ))

        #expect(resolution == EntryReferenceResolution(
            status: .resolved,
            target: EntryReferenceTarget(
                id: "account-b",
                label: "Shared account",
                category: "Accounts"
            )
        ))
        let projection = try #require(resolution.target)
        #expect(Mirror(reflecting: projection).children.compactMap(\.label) == ["id", "label", "category"])
        let reflectedResolution = String(reflecting: resolution)
        #expect(!reflectedResolution.contains("must-not-be-projected"))
        #expect(!reflectedResolution.contains("private-token"))
        #expect(!reflectedResolution.contains("private-secret-key"))
    }

    @Test("Empty value wins before target lookup")
    func emptyValueWinsBeforeTargetLookup() throws {
        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: "   \n"),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [targetEntry(id: "   \n", category: "Other", isDeleted: true)]
        ))

        #expect(resolution == EntryReferenceResolution(status: .empty))
    }

    @Test("Missing target uses case-sensitive exact ID matching")
    func missingTargetUsesCaseSensitiveExactIDMatching() throws {
        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: "Target-ID"),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [targetEntry(id: "target-id", category: "Accounts")]
        ))

        #expect(resolution == EntryReferenceResolution(status: .missing))
    }

    @Test("Deleted target wins before category mismatch")
    func deletedTargetWinsBeforeCategoryMismatch() throws {
        let target = targetEntry(id: "deleted-account", category: "Archive", isDeleted: true)

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ))

        #expect(resolution.status == .deleted)
        #expect(resolution.target?.id == target.id)
        #expect(resolution.target?.category == "Archive")
    }

    @Test("Active target outside the configured category is a mismatch")
    func activeTargetOutsideConfiguredCategoryIsMismatch() throws {
        let target = targetEntry(id: "server-id", category: "Servers")

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ))

        #expect(resolution.status == .categoryMismatch)
        #expect(resolution.target?.id == target.id)
    }

    @Test("Target category comparison trims whitespace and ignores case")
    func targetCategoryComparisonTrimsWhitespaceAndIgnoresCase() throws {
        let target = targetEntry(id: "account-id", category: " Accounts ")

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: " accounts \n"),
            entries: [target]
        ))

        #expect(resolution.status == .resolved)
        #expect(resolution.target?.category == "Accounts")
    }

    @Test("Blank target category does not restrict the target")
    func blankTargetCategoryDoesNotRestrictTarget() throws {
        let target = targetEntry(id: "server-id", category: "Servers")

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "  \n"),
            entries: [target]
        ))

        #expect(resolution.status == .resolved)
        #expect(resolution.target?.category == "Servers")
    }

    @Test("Only matching entry-reference template fields are resolved")
    func onlyMatchingEntryReferenceTemplateFieldsAreResolved() throws {
        let target = targetEntry(id: "account-id", category: "Accounts")
        let textTemplate = CategoryTemplate(
            category: "Servers",
            fields: [FieldTemplate(id: "template-owner", name: "Owner")]
        )

        #expect(resolveEntryReference(
            field: referenceField(value: target.id),
            template: textTemplate,
            entries: [target]
        ) == nil)
        #expect(resolveEntryReference(
            field: CustomField(
                id: "owner-field",
                templateFieldId: "missing-template-id",
                name: "Owner",
                value: target.id
            ),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ) == nil)

        let legacyResolution = try #require(resolveEntryReference(
            field: CustomField(
                id: "owner-field",
                templateFieldId: "",
                name: " owner ",
                value: target.id
            ),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ))
        #expect(legacyResolution.status == .resolved)

        #expect(resolveEntryReference(
            field: CustomField(
                id: "owner-field",
                templateFieldId: "   ",
                name: "Owner",
                value: target.id
            ),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ) == nil)
    }

    @Test("Category rename only updates matching entry-reference targets")
    func categoryRenameOnlyUpdatesMatchingEntryReferenceTargets() {
        let reference = FieldTemplate(
            id: "template-owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: " Accounts "
        )
        let text = FieldTemplate(
            id: "template-text",
            name: "Text",
            valueType: "text",
            targetCategory: "accounts"
        )
        let unknown = FieldTemplate(
            id: "template-future",
            name: "Future",
            valueType: "futureReference",
            targetCategory: "ACCOUNTS"
        )
        let templates = [
            CategoryTemplate(category: "Servers", fields: [reference, text, unknown]),
            CategoryTemplate(
                category: "Services",
                fields: [FieldTemplate(
                    id: "template-service-owner",
                    name: "Service Owner",
                    valueType: "entryReference",
                    targetCategory: "accounts"
                )]
            )
        ]

        let renamed = propagateEntryReferenceCategoryRename(
            templates: templates,
            from: " accounts\n",
            to: " Identity "
        )

        #expect(renamed[0].fields[0] == FieldTemplate(
            id: reference.id,
            name: reference.name,
            valueType: reference.valueType,
            targetCategory: "Identity"
        ))
        #expect(renamed[0].fields[1] == text)
        #expect(renamed[0].fields[2] == unknown)
        #expect(renamed[1].fields[0].targetCategory == "Identity")
    }

    @MainActor
    @Test("Vault lifecycle preserves reference values and updates resolution state")
    func vaultLifecyclePreservesReferenceValuesAndUpdatesResolutionState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSReferenceLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        let reference = FieldTemplate(
            id: "template-owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: " Accounts "
        )
        let text = FieldTemplate(
            id: "template-text",
            name: "Text",
            valueType: "text",
            targetCategory: "Accounts"
        )
        let unknown = FieldTemplate(
            id: "template-future",
            name: "Future",
            valueType: "futureReference",
            targetCategory: "ACCOUNTS"
        )
        let target = targetEntry(id: "target-id", category: "Accounts")
        let source = VaultEntry(
            id: "source-id",
            label: "Server",
            type: .credential,
            payload: .credential(CredentialPayload(category: "Servers")),
            customFields: [referenceField(value: target.id)]
        )
        let snapshot = VaultSnapshot(
            entries: [target, source],
            categories: ["Accounts", "Archive", "Servers"],
            categoryTemplates: [
                CategoryTemplate(category: "Accounts"),
                CategoryTemplate(category: "Archive"),
                CategoryTemplate(category: "Servers", fields: [reference, text, unknown])
            ]
        )
        let importURL = directory.appendingPathComponent("reference-lifecycle.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try repository.encodeSnapshot(snapshot).write(to: importURL)
        store.importSnapshot(from: importURL)

        #expect(store.renameCategory(" accounts ", to: " Identity "))
        let renamedTemplate = try #require(store.categoryTemplates.first { $0.category == "Servers" })
        let renamedReference = try #require(renamedTemplate.fields.first { $0.id == reference.id })
        #expect(renamedReference == FieldTemplate(
            id: reference.id,
            name: reference.name,
            valueType: reference.valueType,
            targetCategory: "Identity"
        ))
        #expect(renamedTemplate.fields.first { $0.id == text.id } == text)
        #expect(renamedTemplate.fields.first { $0.id == unknown.id } == unknown)
        #expect(referenceStatus(store: store, sourceID: source.id) == .resolved)

        let liveTarget = try #require(store.entries.first { $0.id == target.id })
        store.delete(liveTarget)
        #expect(referenceValue(store: store, sourceID: source.id) == target.id)
        #expect(referenceStatus(store: store, sourceID: source.id) == .deleted)

        let deletedTarget = try #require(store.entries.first { $0.id == target.id })
        var restoreDraft = EntryDraft(entry: deletedTarget)
        restoreDraft.category = "Identity"
        store.upsert(restoreDraft, editing: deletedTarget)
        #expect(referenceValue(store: store, sourceID: source.id) == target.id)
        #expect(referenceStatus(store: store, sourceID: source.id) == .resolved)

        #expect(store.deleteCategory(" identity "))
        #expect(referenceValue(store: store, sourceID: source.id) == target.id)
        #expect(referenceTargetCategory(store: store, sourceID: source.id) == "Identity")
        #expect(referenceStatus(store: store, sourceID: source.id) == .categoryMismatch)

        let uncategorizedTarget = try #require(store.entries.first { $0.id == target.id })
        var moveDraft = EntryDraft(entry: uncategorizedTarget)
        moveDraft.category = "Archive"
        store.upsert(moveDraft, editing: uncategorizedTarget)
        #expect(referenceValue(store: store, sourceID: source.id) == target.id)
        #expect(referenceStatus(store: store, sourceID: source.id) == .categoryMismatch)
    }

    @MainActor
    private func referenceStatus(store: VaultStore, sourceID: String) -> EntryReferenceStatus? {
        guard let source = store.entries.first(where: { $0.id == sourceID }),
              let template = store.categoryTemplates.first(where: {
                  $0.category.caseInsensitiveCompare(source.payload.category) == .orderedSame
              }),
              let field = source.customFields.first else {
            return nil
        }
        return resolveEntryReference(field: field, template: template, entries: store.entries)?.status
    }

    @MainActor
    private func referenceValue(store: VaultStore, sourceID: String) -> String? {
        store.entries.first(where: { $0.id == sourceID })?.customFields.first?.value
    }

    @MainActor
    private func referenceTargetCategory(store: VaultStore, sourceID: String) -> String? {
        guard let source = store.entries.first(where: { $0.id == sourceID }) else { return nil }
        return store.categoryTemplates.first(where: {
            $0.category.caseInsensitiveCompare(source.payload.category) == .orderedSame
        })?.fields.first(where: { $0.valueType == "entryReference" })?.targetCategory
    }

    private func referenceTemplate(targetCategory: String) -> CategoryTemplate {
        CategoryTemplate(
            category: "Servers",
            fields: [
                FieldTemplate(
                    id: "template-owner",
                    name: "Owner",
                    valueType: "entryReference",
                    targetCategory: targetCategory
                )
            ]
        )
    }

    private func referenceField(value: String) -> CustomField {
        CustomField(
            id: "owner-field",
            templateFieldId: "template-owner",
            name: "Owner",
            value: value
        )
    }

    private func targetEntry(
        id: String,
        label: String = "Target",
        category: String,
        password: String = "private-password",
        isDeleted: Bool = false
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            label: label,
            type: .credential,
            payload: .credential(CredentialPayload(
                username: "private-user",
                password: password,
                token: "private-token",
                secretKey: "private-secret-key",
                category: category
            )),
            isDeleted: isDeleted
        )
    }
}
