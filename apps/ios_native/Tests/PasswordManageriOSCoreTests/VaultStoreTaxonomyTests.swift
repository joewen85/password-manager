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
}
