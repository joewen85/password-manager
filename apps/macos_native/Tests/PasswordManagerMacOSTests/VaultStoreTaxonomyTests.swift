import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("VaultStore Taxonomy")
struct VaultStoreTaxonomyTests {
    @MainActor
    @Test("Category management matches Android store behavior")
    func categoryManagementMatchesAndroidStoreBehavior() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSTaxonomyCategoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        #expect(store.addCategory(" Work "))
        #expect(store.categories == ["Work"])
        #expect(store.categoryTemplates == [CategoryTemplate(category: "Work")])
        #expect(!store.addCategory("work"))
        #expect(store.statusMessage == "Category already exists.")

        var draft = EntryDraft()
        draft.label = "Work Login"
        draft.category = "Work"
        store.upsert(draft, editing: nil)

        #expect(store.renameCategory("work", to: "Personal"))
        #expect(store.categories == ["Personal"])
        #expect(store.categoryTemplates.first?.category == "Personal")
        #expect(store.entries.first?.payload.category == "Personal")

        #expect(store.deleteCategory("personal"))
        #expect(store.categories == [])
        #expect(store.categoryTemplates == [])
        #expect(store.entries.first?.payload.category == "")
        #expect(!store.deleteCategory("personal"))
        #expect(store.statusMessage == "Category not found.")
    }

    @MainActor
    @Test("Tag management matches Android store behavior")
    func tagManagementMatchesAndroidStoreBehavior() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSTaxonomyTagTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        #expect(store.addTag(" Ops "))
        #expect(store.tags == ["Ops"])
        #expect(!store.addTag("ops"))
        #expect(store.statusMessage == "Tag already exists.")

        var draft = EntryDraft()
        draft.label = "Tagged Login"
        draft.tags = ["Ops"]
        store.upsert(draft, editing: nil)

        #expect(store.renameTag("ops", to: "Prod"))
        #expect(store.tags == ["Prod"])
        #expect(store.entries.first?.payload.tags == ["Prod"])

        #expect(store.deleteTag("prod"))
        #expect(store.tags == [])
        #expect(store.entries.first?.payload.tags == [])
        #expect(!store.deleteTag("prod"))
        #expect(store.statusMessage == "Tag not found.")
    }

    @MainActor
    @Test("Category presets create platform-compatible field templates")
    func categoryPresetsCreatePlatformCompatibleFieldTemplates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSCategoryPresetTests-\(UUID().uuidString)", isDirectory: true)
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

        var draft = EntryDraft()
        draft.applyTemplateFields(template.fields)

        #expect(draft.customFields.map(\.name) == ["名称", "备注", "IP地址", "端口", "关联账号", "Owner"])
    }

    @MainActor
    @Test("Category custom fields are user-defined without requiring a type")
    func categoryCustomFieldsAreUserDefinedWithoutRequiringAType() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSCategoryCustomOnlyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        #expect(store.addCategory("Private", preset: nil, customFieldNames: []))
        #expect(store.categoryTemplates.first { $0.category == "Private" }?.fields.map(\.name) == ["名称", "备注"])

        #expect(store.addCategory("Ops", preset: nil, customFieldNames: ["IP地址", "端口", "Owner", "ip地址", ""]))
        #expect(store.categoryTemplates.first { $0.category == "Ops" }?.fields.map(\.name) == ["名称", "备注", "IP地址", "端口", "Owner"])
    }

    @MainActor
    @Test("Category creation persists complete same-category field references atomically")
    func categoryCreationPersistsCompleteSameCategoryFieldReferencesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSCategoryFieldReferenceCreation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        let email = newCategoryTemplateField(name: "Email")
        let alias = newCategoryTemplateField(
            name: "Alias",
            valueType: "fieldReference",
            targetCategory: "Servers",
            targetFieldId: email.id
        )
        #expect(store.addCategory(
            " Servers ",
            preset: nil,
            customFields: [email, alias]
        ))

        let template = try #require(store.categoryTemplates.first { $0.category == "Servers" })
        #expect(template.fields.first { $0.name == "Email" }?.id == email.id)
        #expect(template.fields.first { $0.name == "Alias" } == alias)

        let selfReference = newCategoryTemplateField(
            name: "Loop",
            valueType: "fieldReference",
            targetCategory: "Broken",
            targetFieldId: "self-reference"
        )
        var invalidSelfReference = selfReference
        invalidSelfReference.id = "self-reference"
        #expect(!store.addCategory(
            "Broken",
            preset: nil,
            customFields: [invalidSelfReference]
        ))
        #expect(!store.categories.contains("Broken"))
        #expect(!store.categoryTemplates.contains { $0.category == "Broken" })
        #expect(store.statusMessage == "Field reference requires a target category and target text field.")

        let reloadedStore = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(reloadedStore.unlock(password: "test-password"))
        let reloaded = try #require(reloadedStore.categoryTemplates.first { $0.category == "Servers" })
        #expect(reloaded.fields.first { $0.id == alias.id } == alias)
    }

    @MainActor
    @Test("Category creation rejects duplicate editable field names atomically")
    func categoryCreationRejectsDuplicateEditableFieldNamesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSCategoryDuplicateFieldCreation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        #expect(!store.addCategory(
            "DefaultConflict",
            preset: nil,
            customFields: [newCategoryTemplateField(name: " 备注 ")]
        ))
        #expect(store.statusMessage == "Field name already exists: 备注.")

        #expect(!store.addCategory(
            "CustomConflict",
            preset: nil,
            customFields: [
                newCategoryTemplateField(name: "Owner"),
                newCategoryTemplateField(name: " owner ")
            ]
        ))
        #expect(store.statusMessage == "Field name already exists: owner.")

        #expect(!store.addCategory(
            "PresetConflict",
            preset: .server,
            customFields: [newCategoryTemplateField(name: " ip地址 ")]
        ))
        #expect(store.statusMessage == "Field name already exists: ip地址.")

        for category in ["DefaultConflict", "CustomConflict", "PresetConflict"] {
            #expect(!store.categories.contains(category))
            #expect(!store.categoryTemplates.contains { $0.category == category })
        }

        let reloadedStore = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(reloadedStore.unlock(password: "test-password"))
        #expect(reloadedStore.categories.isEmpty)
        #expect(reloadedStore.categoryTemplates.isEmpty)
    }

    @MainActor
    @Test("Category template updates persist and reconfigure saved entry fields")
    func categoryTemplateUpdatesPersistAndReconfigureSavedEntryFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSCategoryTemplateUpdateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(
            repository: repository,
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        #expect(store.addCategory("Ops", preset: nil, customFieldNames: ["Owner"]))
        let initialTemplate = try #require(store.categoryTemplates.first { $0.category == "Ops" })

        var draft = EntryDraft(category: "Ops", templateFields: initialTemplate.fields)
        draft.label = "Deploy"
        draft.customFields[0].value = "keep this note"
        draft.customFields[1].value = "alice"
        store.upsert(draft, editing: nil)

        #expect(store.updateCategoryTemplate("ops", customFieldNames: ["Endpoint", "备注", "endpoint", ""]))
        let updatedTemplate = try #require(store.categoryTemplates.first { $0.category == "Ops" })
        #expect(updatedTemplate.fields.map(\.name) == ["名称", "备注", "Endpoint", "Owner"])

        let savedEntry = try #require(store.entries.first)
        var editDraft = EntryDraft(entry: savedEntry)
        editDraft.configureTemplateFields(updatedTemplate.fields)

        #expect(editDraft.customFields.filter {
            !editDraft.protectedCustomFieldIds.contains($0.id)
        }.map(\.name) == ["备注", "Endpoint", "Owner"])
        #expect(editDraft.customFields.first { $0.name == "备注" }?.value == "keep this note")
        #expect(editDraft.customFields.first { $0.name == "Endpoint" }?.value == "")
        #expect(editDraft.customFields.first { $0.name == "Owner" }?.value == "alice")

        let reloadedStore = VaultStore(
            repository: repository,
            syncSettingsRepository: nil
        )
        #expect(reloadedStore.unlock(password: "test-password"))
        #expect(reloadedStore.categoryTemplates.first { $0.category == "Ops" }?.fields.map(\.name) == ["名称", "备注", "Endpoint", "Owner"])
    }

    @MainActor
    @Test("Category template editing preserves stable IDs and unsupported field metadata")
    func categoryTemplateEditingPreservesStableIdsAndUnsupportedMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSTemplateMetadataTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        #expect(store.addCategory("Ops", preset: nil, customFieldNames: ["Owner"]))

        let ownerField = try #require(
            store.categoryTemplates.first?.fields.first { $0.name == "Owner" }
        )
        let referenceField = FieldTemplate(
            id: "template_account",
            name: "Account",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let futureField = FieldTemplate(
            id: "opaque-template:future",
            name: "Future",
            valueType: "futureRelationV3",
            targetCategory: "Targets"
        )
        let scopedExport = ScopedVaultExport(
            scope: .item,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            item: nil,
            category: nil,
            items: nil,
            categoryTemplates: [
                CategoryTemplate(
                    category: "Ops",
                    fields: [ownerField, referenceField, futureField]
                )
            ]
        )
        let importURL = directory.appendingPathComponent("template-metadata-import.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(scopedExport).write(to: importURL)
        store.importScopedExport(from: importURL, strategy: .skip)

        #expect(store.updateCategoryTemplate(
            "ops",
            customFields: [
                CustomField(
                    templateFieldId: ownerField.id,
                    name: "Primary Owner"
                ),
                CustomField(name: "Account")
            ]
        ))

        let updatedTemplate = try #require(store.categoryTemplates.first)
        let renamedOwner = try #require(updatedTemplate.fields.first { $0.name == "Primary Owner" })
        #expect(renamedOwner.id == ownerField.id)
        #expect(renamedOwner.valueType == "text")
        #expect(updatedTemplate.fields.contains(referenceField))
        #expect(updatedTemplate.fields.contains(futureField))
        #expect(updatedTemplate.fields.filter { $0.name == "Account" } == [referenceField])

        let reloadedStore = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(reloadedStore.unlock(password: "test-password"))
        let reloadedTemplate = try #require(reloadedStore.categoryTemplates.first)
        #expect(reloadedTemplate.fields.first { $0.name == "Primary Owner" }?.id == ownerField.id)
        #expect(reloadedTemplate.fields.contains(referenceField))
        #expect(reloadedTemplate.fields.contains(futureField))
    }
}
