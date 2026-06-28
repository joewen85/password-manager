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
}
