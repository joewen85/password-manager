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

        #expect(store.addCategory("Infra", preset: .server))

        let template = try #require(store.categoryTemplates.first)
        #expect(template.category == "Infra")
        #expect(template.fields.map(\.name) == ["名称", "备注", "IP地址", "端口", "关联账号"])

        var draft = EntryDraft()
        draft.applyTemplateFields(template.fields)

        #expect(draft.customFields.map(\.name) == ["名称", "备注", "IP地址", "端口", "关联账号"])
    }
}
