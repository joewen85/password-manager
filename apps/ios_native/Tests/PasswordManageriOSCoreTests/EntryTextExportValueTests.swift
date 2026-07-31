import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("Entry Text Export Values")
struct EntryTextExportValueTests {
    @Test("Template entries expose their stored custom values without empty legacy duplicates")
    func templateEntriesExposeStoredCustomValues() {
        let username = CustomField(id: "username-field", name: "用户名", value: "template-user")
        let password = CustomField(id: "password-field", name: "密码", value: "template-password")
        let entry = VaultEntry(
            label: "Template Credential",
            type: .credential,
            payload: .credential(CredentialPayload(category: "Accounts")),
            customFields: [username, password]
        )

        #expect(!entry.exportFields.contains { $0.id == "credential.username" })
        #expect(!entry.exportFields.contains { $0.id == "credential.password" })
        #expect(entry.selectedFieldsText(
            selectedFieldIDs: ["custom.\(username.id)", "custom.\(password.id)"],
            categoryTemplates: [],
            entries: [entry]
        ) == [
            "用户名: template-user",
            "密码: template-password"
        ].joined(separator: "\n"))
    }

    @Test("Credential values and server account references are exported")
    func credentialValuesAndServerAccountReferencesAreExported() {
        let account = VaultEntry(
            id: "account-entry",
            label: "Primary Account",
            type: .credential,
            payload: .credential(CredentialPayload())
        )
        let credential = VaultEntry(
            label: "Credential",
            type: .credential,
            payload: .credential(CredentialPayload(
                username: "saved-user",
                password: "saved-password"
            ))
        )
        let server = VaultEntry(
            label: "Server",
            type: .server,
            payload: .server(ServerPayload(
                username: "root",
                password: "server-password",
                accountId: account.id
            ))
        )

        #expect(credential.selectedFieldsText(
            selectedFieldIDs: ["credential.username", "credential.password"],
            categoryTemplates: [],
            entries: [credential]
        ) == [
            "Username: saved-user",
            "Password: saved-password"
        ].joined(separator: "\n"))
        #expect(server.exportFields.contains { $0.id == "server.accountId" })
        #expect(server.selectedFieldsText(
            selectedFieldIDs: ["server.username", "server.password", "server.accountId"],
            categoryTemplates: [],
            entries: [server, account]
        ) == [
            "Username: root",
            "Password: server-password",
            "Account ID: Primary Account"
        ].joined(separator: "\n"))

        guard case .server(let selectedServer) = server
            .keepingExportFields(["server.accountId"])
            .payload else {
            Issue.record("Selected export should keep the server payload type.")
            return
        }
        #expect(selectedServer.accountId == account.id)
    }

    @MainActor
    @Test("Store export reloads the current entry values")
    func storeExportReloadsCurrentEntryValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSCurrentEntryExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        var initialDraft = EntryDraft()
        initialDraft.label = "Credential"
        initialDraft.credential = CredentialPayload(username: "old-user", password: "old-password")
        #expect(store.upsert(initialDraft, editing: nil))
        let staleEntry = try #require(store.entries.first)

        var updatedDraft = EntryDraft(entry: staleEntry)
        updatedDraft.credential.username = "current-user"
        updatedDraft.credential.password = "current-password"
        #expect(store.upsert(updatedDraft, editing: staleEntry))

        store.exportSelectedEntryText(
            staleEntry,
            selectedFieldIDs: ["credential.username", "credential.password"]
        )
        let exportFiles = try FileManager.default.contentsOfDirectory(
            at: repository.exportsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        let exportURL = try #require(exportFiles.first { $0.pathExtension == "txt" })
        #expect(try String(contentsOf: exportURL, encoding: .utf8) == [
            "Username: current-user",
            "Password: current-password"
        ].joined(separator: "\n"))
    }
}
