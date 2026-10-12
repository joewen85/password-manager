#if DEBUG && targetEnvironment(simulator)
import Foundation

// Each UI test run uses a fresh encrypted repository, separate from the user's vault.
@MainActor
enum DebugUIFixture {
    static func makeStore(includeManyCategories: Bool = false) -> VaultStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuoUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        let password = "disposable-ui-fixture"
        precondition(store.setupMasterPassword(password, confirmation: password))
        for (label, type) in [("Duo Test Alpha", VaultEntryType.credential), ("Duo Test Beta", .server)] {
            var draft = EntryDraft()
            draft.label = label
            draft.type = type
            draft.tags = ["Duo"]
            precondition(store.upsert(draft, editing: nil))
        }
        if includeManyCategories {
            for index in 1...7 {
                precondition(store.addCategory("Duo Category \(index)", preset: nil, customFields: []))
            }
            for index in 1...24 {
                var draft = EntryDraft()
                draft.label = "Duo Scroll Entry \(index)"
                draft.category = "Duo Category 1"
                precondition(store.upsert(draft, editing: nil))
            }
        }
        return store
    }
}
#endif
