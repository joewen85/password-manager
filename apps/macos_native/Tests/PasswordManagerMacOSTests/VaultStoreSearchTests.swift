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
}
