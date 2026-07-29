import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("VaultStore Taxonomy")
struct VaultStoreTaxonomyTests {
    @MainActor
    @Test("Category presets accept custom field names")
    func categoryPresetsAcceptCustomFieldNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSCategoryCustomFieldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        #expect(store.addCategory("Infra", preset: .server, customFieldNames: ["Owner", "备注", ""]))

        let template = try #require(store.categoryTemplates.first)
        #expect(template.category == "Infra")
        #expect(template.fields.map(\.name) == ["名称", "备注", "IP地址", "端口", "关联账号", "Owner"])
    }

    @MainActor
    @Test("Category custom fields are user-defined without requiring a type")
    func categoryCustomFieldsAreUserDefinedWithoutRequiringAType() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSCategoryCustomOnlyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        #expect(store.addCategory("Private", preset: nil, customFieldNames: []))
        #expect(store.categoryTemplates.first { $0.category == "Private" }?.fields.map(\.name) == ["名称", "备注"])

        #expect(store.addCategory("Ops", preset: nil, customFieldNames: ["服务入口", "关联账号", "Owner", "服务入口", ""]))
        #expect(store.categoryTemplates.first { $0.category == "Ops" }?.fields.map(\.name) == ["名称", "备注", "服务入口", "关联账号", "Owner"])
    }

    @MainActor
    @Test("Category template saves reject duplicate editable field names atomically")
    func categoryTemplateRejectsDuplicateEditableNamesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSCategoryDuplicateFieldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        #expect(store.addCategory("Infra"))

        let defaults = try #require(store.categoryTemplate(for: "Infra"))
        #expect(!store.updateCategoryTemplate(
            category: "Infra",
            requestedCustomFields: [FieldTemplate(name: " 备注 ")]
        ))
        #expect(store.statusMessage == "Field name already exists: 备注.")
        #expect(store.categoryTemplate(for: "Infra") == defaults)

        #expect(!store.updateCategoryTemplate(
            category: "Infra",
            requestedCustomFields: [FieldTemplate(name: "Owner"), FieldTemplate(name: " owner ")]
        ))
        #expect(store.statusMessage == "Field name already exists: owner.")
        #expect(store.categoryTemplate(for: "Infra") == defaults)

        let owner = FieldTemplate(id: "owner", name: "Owner")
        let reference = FieldTemplate(
            id: "stored-reference",
            name: "Account",
            valueType: "fieldReference",
            targetCategory: "Infra",
            targetFieldId: owner.id
        )
        #expect(store.updateCategoryTemplate(
            category: "Infra",
            requestedCustomFields: [owner, reference]
        ))
        let configured = try #require(store.categoryTemplate(for: "Infra"))

        var draft = EntryDraft(category: "Infra", templateFields: configured.fields)
        draft.label = "Gateway"
        let referenceIndex = try #require(draft.customFields.firstIndex {
            $0.templateFieldId == reference.id
        })
        draft.customFields[referenceIndex].value = "opaque-target"
        #expect(store.upsert(draft, editing: nil))
        #expect(store.categoryTemplateStoredValueFieldIds("Infra").contains(reference.id))

        var conflictingReference = reference
        conflictingReference.name = " owner "
        #expect(!store.updateCategoryTemplate(
            category: "Infra",
            requestedCustomFields: [owner, conflictingReference]
        ))
        #expect(store.statusMessage == "Field name already exists: owner.")
        #expect(store.categoryTemplate(for: "Infra") == configured)
    }

    @MainActor
    @Test("Only live source values keep a category field locked")
    func deletedSourcesDoNotKeepTemplateFieldsLocked() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSLiveTemplateValueGate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        #expect(store.addCategory("Accounts"))
        #expect(store.addCategory("Original"))

        let nameField = try #require(CategoryTemplate.defaultFields.first { $0.name == "名称" })
        let reference = FieldTemplate(
            id: "stored-reference",
            name: "Owner",
            valueType: "fieldReference",
            targetCategory: "Accounts",
            targetFieldId: nameField.id
        )
        #expect(store.updateCategoryTemplate(
            category: "Original",
            requestedCustomFields: [reference]
        ))

        var targetDraft = EntryDraft(
            category: "Accounts",
            templateFields: try #require(store.categoryTemplate(for: "Accounts")?.fields)
        )
        targetDraft.label = "Account"
        #expect(store.upsert(targetDraft, editing: nil))
        let target = try #require(store.entries.first { $0.label == "Account" })

        let configured = try #require(store.categoryTemplate(for: "Original"))
        var sourceDraft = EntryDraft(category: "Original", templateFields: configured.fields)
        sourceDraft.label = "Source"
        let referenceIndex = try #require(sourceDraft.customFields.firstIndex {
            $0.templateFieldId == reference.id
        })
        sourceDraft.customFields[referenceIndex].value = target.id
        #expect(store.upsert(sourceDraft, editing: nil))
        let source = try #require(store.entries.first { $0.label == "Source" })

        store.delete(target)
        #expect(store.categoryTemplateStoredValueFieldIds("Original") == [reference.id])
        #expect(store.updateEntryReference(entryID: source.id, fieldID: source.customFields[referenceIndex].id, targetID: ""))
        #expect(store.categoryTemplateStoredValueFieldIds("Original").isEmpty)

        sourceDraft.label = "Deleted Source"
        sourceDraft.customFields[referenceIndex].value = target.id
        #expect(store.upsert(sourceDraft, editing: nil))
        let deletedSource = try #require(store.entries.first { $0.label == "Deleted Source" })
        store.delete(deletedSource)
        #expect(store.categoryTemplateStoredValueFieldIds("Original").isEmpty)

        #expect(store.updateCategoryTemplate(category: "Original", requestedCustomFields: []))
        #expect(store.categoryTemplate(for: "Original")?.fields.contains { $0.id == reference.id } == false)
    }
}
