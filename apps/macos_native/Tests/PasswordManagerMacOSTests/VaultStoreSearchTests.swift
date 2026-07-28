import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("VaultStore Search")
struct VaultStoreSearchTests {
    @MainActor
    @Test("Structured key-value search matches typed and custom fields")
    func structuredKeyValueSearchMatchesTypedAndCustomFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSSearchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        var serverDraft = EntryDraft(entry: VaultEntry(
            label: "Production Gateway",
            type: .server,
            payload: .server(ServerPayload(
                name: "gateway-prod",
                ipAddress: "1.2.3.4",
                port: "22",
                username: "root"
            )),
            customFields: [CustomField(name: "Owner", value: "sre-team")]
        ))
        serverDraft.category = "Infra"
        serverDraft.tags = ["prod"]
        store.upsert(serverDraft, editing: nil)

        var serviceDraft = EntryDraft(entry: VaultEntry(
            label: "Billing Service",
            type: .service,
            payload: .service(ServicePayload(
                name: "billing-api",
                connectionAddress: "https://billing.example.com",
                connectionPort: "443"
            )),
            customFields: [CustomField(name: "Region", value: "ap-south")]
        ))
        serviceDraft.category = "Apps"
        serviceDraft.tags = ["billing"]
        store.upsert(serviceDraft, editing: nil)

        #expect(store.filteredEntries(searchText: "ip:1.2.3.4", filter: .all).map(\.label) == ["Production Gateway"])
        #expect(store.filteredEntries(searchText: "name:billing-api", filter: .all).map(\.label) == ["Billing Service"])
        #expect(store.filteredEntries(searchText: "https://billing.example.com", filter: .all).map(\.label) == ["Billing Service"])
        #expect(store.filteredEntries(searchText: "owner:sre-team", filter: .all).map(\.label) == ["Production Gateway"])
        #expect(store.filteredEntries(searchText: "region:ap-south", filter: .all).map(\.label) == ["Billing Service"])
        #expect(store.filteredEntries(searchText: "tag:prod ip:1.2.3.4", filter: .all).map(\.label) == ["Production Gateway"])
        #expect(store.filteredEntries(searchText: "ip:9.9.9.9", filter: .all).isEmpty)
    }

    @MainActor
    @Test("Reference search uses only resolved target label and category")
    func referenceSearchUsesOnlyResolvedTargetLabelAndCategory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSReferenceSearchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        let ownerTemplate = FieldTemplate(
            id: "template_owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let templateExport = ScopedVaultExport(
            scope: .item,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            item: nil,
            category: nil,
            items: nil,
            categoryTemplates: [CategoryTemplate(category: "Servers", fields: [ownerTemplate])]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fileName = "reference-search-template.json"
        try encoder.encode(templateExport).write(
            to: try repository.importsDirectoryURL.appendingPathComponent(fileName)
        )
        store.importScopedExport(fileName: fileName, strategy: .skip)

        var targetDraft = EntryDraft(entry: VaultEntry(
            label: "Payroll Account",
            type: .credential,
            payload: .credential(CredentialPayload(
                password: "target-password-secret",
                token: "target-token-secret",
                secretKey: "target-key-secret",
                category: "Accounts"
            ))
        ))
        targetDraft.category = "Accounts"
        store.upsert(targetDraft, editing: nil)
        let target = try #require(store.entries.first { $0.label == targetDraft.label })

        var sourceDraft = EntryDraft(entry: VaultEntry(
            label: "Payroll Server",
            type: .server,
            payload: .server(ServerPayload(category: "Servers")),
            customFields: [
                CustomField(
                    id: "owner-field",
                    templateFieldId: ownerTemplate.id,
                    name: ownerTemplate.name,
                    value: target.id
                )
            ]
        ))
        sourceDraft.category = "Servers"
        store.upsert(sourceDraft, editing: nil)
        let source = try #require(store.entries.first { $0.label == sourceDraft.label })

        #expect(store.filteredEntries(searchText: target.label, filter: .all).contains { $0.id == source.id })
        #expect(store.filteredEntries(searchText: "owner:Accounts", filter: .all).contains { $0.id == source.id })
        #expect(!store.filteredEntries(searchText: target.id, filter: .all).contains { $0.id == source.id })
        for secret in ["target-password-secret", "target-token-secret", "target-key-secret"] {
            #expect(!store.filteredEntries(searchText: secret, filter: .all).contains { $0.id == source.id })
        }

        var movedTarget = EntryDraft(entry: target)
        movedTarget.category = "Archive"
        store.upsert(movedTarget, editing: target)

        #expect(!store.filteredEntries(searchText: target.label, filter: .all).contains { $0.id == source.id })
    }
}
