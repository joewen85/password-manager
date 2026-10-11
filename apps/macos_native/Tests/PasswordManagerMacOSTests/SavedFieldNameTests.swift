import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("Saved field names")
struct SavedFieldNameTests {
    @MainActor
    @Test("Saved entry names stay fixed while values, deletion, and new fields remain editable")
    func entryFieldLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        var draft = EntryDraft()
        draft.label = "Entry"
        draft.customFields = [CustomField(id: "original", name: "Owner", value: "alice")]
        store.upsert(draft, editing: nil)
        let saved = try #require(store.entries.first)
        var edited = EntryDraft(entry: saved)
        edited.customFields[0].name = "Renamed"
        edited.customFields[0].value = "bob"
        edited.customFields.append(CustomField(id: "new", name: "Region", value: "east"))
        store.upsert(edited, editing: saved)
        store.lock()
        #expect(store.unlock(password: "test-password"))
        let reloaded = try #require(store.entries.first)
        #expect(reloaded.customFields.first { $0.id == "original" }?.name == "Owner")
        #expect(reloaded.customFields.first { $0.id == "original" }?.value == "bob")
        #expect(reloaded.customFields.first { $0.id == "new" }?.name == "Region")
        var replacementDraft = EntryDraft(entry: reloaded)
        replacementDraft.customFields.removeAll { $0.id == "original" }
        replacementDraft.customFields.append(CustomField(id: "replacement", name: "Primary Owner", value: "carol"))
        store.upsert(replacementDraft, editing: reloaded)
        #expect(!store.entries[0].customFields.contains { $0.id == "original" })
        #expect(store.entries[0].customFields.first { $0.id == "replacement" }?.name == "Primary Owner")
        var secondEdit = EntryDraft(entry: store.entries[0])
        secondEdit.customFields[0].name = "Cannot rename new saved field"
        store.upsert(secondEdit, editing: store.entries[0])
        #expect(store.entries[0].customFields.first { $0.id == "new" }?.name == "Region")
    }

    @MainActor
    @Test("Saved category field names require deletion and a new ID to change")
    func categoryFieldLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(repository: FileVaultRepository(baseDirectory: directory), syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        #expect(store.addCategory("Accounts", preset: nil, customFieldNames: ["Owner"]))
        let field = try #require(store.categoryTemplates.first?.fields.first { $0.name == "Owner" })
        var renamed = field
        renamed.name = "Primary Owner"
        #expect(store.updateCategoryTemplate("Accounts", fields: [renamed]))
        #expect(store.categoryTemplates.first?.fields.first { $0.id == field.id }?.name == "Owner")
        #expect(store.updateCategoryTemplate("Accounts", fields: []))
        #expect(!store.categoryTemplates[0].fields.contains { $0.id == field.id })
        let replacement = FieldTemplate(id: "replacement", name: "Primary Owner")
        #expect(store.updateCategoryTemplate("Accounts", fields: [replacement]))
        #expect(store.categoryTemplates[0].fields.contains { $0.id == "replacement" && $0.name == "Primary Owner" })
    }
}
