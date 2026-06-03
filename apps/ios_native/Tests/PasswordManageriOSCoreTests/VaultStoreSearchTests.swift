import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("VaultStore Search")
struct VaultStoreSearchTests {
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
}
