import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("VaultStore Search")
struct VaultStoreSearchTests {
    @MainActor
    @Test("Equal update timestamps use entry ID as a stable display order")
    func equalUpdateTimestampsUseEntryIDAsStableDisplayOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSStableEntryOrderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let laterID = VaultEntry(
            id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            label: "Later ID",
            type: .credential,
            payload: .credential(CredentialPayload()),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let earlierID = VaultEntry(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            label: "Earlier ID",
            type: .credential,
            payload: .credential(CredentialPayload()),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let fileName = "stable-order.json"
        try repository.encodeSnapshot(VaultSnapshot(entries: [laterID, earlierID]))
            .write(to: try repository.importsDirectoryURL.appendingPathComponent(fileName))
        store.importSnapshot(fileName: fileName)

        #expect(store.filteredEntries(searchText: "", filter: .all).map(\.id) == [earlierID.id, laterID.id])
    }

    @MainActor
    @Test("Structured key-value search matches typed and custom fields")
    func structuredKeyValueSearchMatchesTypedAndCustomFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSSearchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        var serverDraft = EntryDraft()
        serverDraft.label = "Production Gateway"
        serverDraft.type = .server
        serverDraft.server = ServerPayload(
            name: "gateway-prod",
            ipAddress: "1.2.3.4",
            port: "22",
            username: "root"
        )
        serverDraft.category = "Infra"
        serverDraft.tags = ["prod"]
        serverDraft.customFields = [CustomField(name: "Owner", value: "sre-team")]
        store.upsert(serverDraft, editing: nil)

        var serviceDraft = EntryDraft()
        serviceDraft.label = "Billing Service"
        serviceDraft.type = .service
        serviceDraft.service = ServicePayload(
            name: "billing-api",
            connectionAddress: "https://billing.example.com",
            connectionPort: "443"
        )
        serviceDraft.category = "Apps"
        serviceDraft.tags = ["billing"]
        serviceDraft.customFields = [CustomField(name: "Region", value: "ap-south")]
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
            .appendingPathComponent("PasswordManageriOSReferenceSearchTests-\(UUID().uuidString)", isDirectory: true)
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

        var targetDraft = EntryDraft()
        targetDraft.label = "Payroll Account"
        targetDraft.credential = CredentialPayload(
            password: "target-password-secret",
            token: "target-token-secret",
            secretKey: "target-key-secret"
        )
        targetDraft.category = "Accounts"
        store.upsert(targetDraft, editing: nil)
        let target = try #require(store.entries.first { $0.label == targetDraft.label })

        var sourceDraft = EntryDraft()
        sourceDraft.label = "Payroll Server"
        sourceDraft.type = .server
        sourceDraft.server = ServerPayload()
        sourceDraft.category = "Servers"
        sourceDraft.customFields = [
            CustomField(
                id: "owner-field",
                templateFieldId: ownerTemplate.id,
                name: ownerTemplate.name,
                value: target.id
            )
        ]
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
