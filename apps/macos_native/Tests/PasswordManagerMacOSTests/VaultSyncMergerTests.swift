import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("VaultSyncMerger")
struct VaultSyncMergerTests {
    @Test("Merge keeps additions from both sides")
    func mergeKeepsAdditionsFromBothSides() {
        var counter = 0
        let merger = VaultSyncMerger(
            idGenerator: {
                defer { counter += 1 }
                return "00000000-0000-0000-0000-\(String(format: "%012d", counter))"
            },
            conflictLabelBuilder: { _, _ in "(conflict)" },
            conflictStrategy: .keepBoth
        )
        let local = [
            buildEntry(id: "11111111-1111-1111-1111-111111111111", label: "Local", updatedBy: "A", version: ["A": 1])
        ]
        let remote = [
            buildEntry(id: "22222222-2222-2222-2222-222222222222", label: "Remote", updatedBy: "B", version: ["B": 1])
        ]

        let result = merger.merge(localEntries: local, remoteEntries: remote)

        #expect(result.entries.count == 2)
        #expect(result.stats.conflicts == 0)
    }

    @Test("Vault entry JSON encoding preserves opaque identifiers")
    func vaultEntryJSONEncodingPreservesOpaqueIdentifiers() throws {
        let entry = buildEntry(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            label: "Canonical",
            updatedBy: "macos",
            version: ["macos": 1]
        )
        var entryWithCustomField = entry
        entryWithCustomField.customFields = [
            CustomField(
                id: "harmony-field:owner",
                name: "Field",
                value: "Value"
            )
        ]

        let data = try JSONEncoder().encode(entryWithCustomField)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try #require(object["customFields"] as? [[String: Any]])

        #expect(object["id"] as? String == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(fields.first?["id"] as? String == "harmony-field:owner")
    }

    @Test("Concurrent rename conflict produces conflict copy")
    func concurrentRenameConflictProducesConflictCopy() {
        var counter = 0
        let merger = VaultSyncMerger(
            idGenerator: {
                defer { counter += 1 }
                return "00000000-0000-0000-0000-\(String(format: "%012d", counter))"
            },
            conflictLabelBuilder: { _, _ in "(conflict)" },
            conflictStrategy: .localWins
        )
        let local = [
            buildEntry(
                id: "33333333-3333-3333-3333-333333333333",
                label: "Name-A",
                updatedBy: "A",
                version: ["A": 2, "B": 1]
            )
        ]
        let remote = [
            buildEntry(
                id: "33333333-3333-3333-3333-333333333333",
                label: "Name-B",
                updatedBy: "B",
                version: ["A": 1, "B": 2]
            )
        ]

        let result = merger.merge(localEntries: local, remoteEntries: remote)

        #expect(result.stats.conflicts == 1)
        #expect(result.entries.count == 2)
        #expect(result.entries.filter { $0.id == "33333333-3333-3333-3333-333333333333" }.count == 1)
        #expect(result.entries.contains { $0.label.contains("Name-B") })
    }

    @Test("Delete vs update keeps tombstone and conflict copy")
    func deleteVsUpdateKeepsTombstoneAndConflictCopy() {
        var counter = 0
        let merger = VaultSyncMerger(
            idGenerator: {
                defer { counter += 1 }
                return "00000000-0000-0000-0000-\(String(format: "%012d", counter))"
            },
            conflictLabelBuilder: { _, _ in "(conflict)" },
            conflictStrategy: .keepBoth
        )
        let sharedId = "44444444-4444-4444-4444-444444444444"
        let local = [
            buildEntry(
                id: sharedId,
                label: "Delete-Me",
                updatedBy: "A",
                version: ["A": 2, "B": 1],
                isDeleted: true
            )
        ]
        let remote = [
            buildEntry(
                id: sharedId,
                label: "Delete-Me",
                updatedBy: "B",
                version: ["A": 1, "B": 2]
            )
        ]

        let result = merger.merge(localEntries: local, remoteEntries: remote)

        #expect(result.stats.conflicts == 1)
        #expect(result.entries.contains { $0.id == sharedId && $0.isDeleted })
        #expect(result.entries.contains { $0.id != sharedId && !$0.isDeleted })
    }

    @Test("Both delete keeps single tombstone")
    func bothDeleteKeepsSingleTombstone() {
        var counter = 0
        let merger = VaultSyncMerger(
            idGenerator: {
                defer { counter += 1 }
                return "00000000-0000-0000-0000-\(String(format: "%012d", counter))"
            },
            conflictLabelBuilder: { _, _ in "(conflict)" },
            conflictStrategy: .keepBoth
        )
        let sharedId = "55555555-5555-5555-5555-555555555555"
        let local = [
            buildEntry(
                id: sharedId,
                label: "Gone",
                updatedBy: "A",
                version: ["A": 2, "B": 1],
                isDeleted: true
            )
        ]
        let remote = [
            buildEntry(
                id: sharedId,
                label: "Gone",
                updatedBy: "B",
                version: ["A": 1, "B": 2],
                isDeleted: true
            )
        ]

        let result = merger.merge(localEntries: local, remoteEntries: remote)

        #expect(result.stats.conflicts == 0)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.isDeleted == true)
    }

    @Test("Conflict copies preserve custom field references")
    func conflictCopiesPreserveCustomFieldReferences() {
        let merger = VaultSyncMerger(
            idGenerator: { "conflict-copy" },
            conflictLabelBuilder: { _, _ in "(conflict)" },
            conflictStrategy: .keepBoth
        )
        var local = buildEntry(
            id: "harmony-entry:server",
            label: "Server",
            updatedBy: "A",
            version: ["A": 2, "B": 1]
        )
        local.customFields = [
            CustomField(
                id: "harmony-field:owner",
                templateFieldId: "template_owner",
                name: "Owner",
                value: "harmony-entry:account-a"
            )
        ]
        var remote = local
        remote.version = ["A": 1, "B": 2]
        remote.updatedBy = "B"
        remote.customFields[0].value = "harmony-entry:account-b"

        let result = merger.merge(localEntries: [local], remoteEntries: [remote])

        #expect(result.stats.conflicts == 1)
        #expect(Set(result.entries.flatMap(\.customFields).map(\.value)) == [
            "harmony-entry:account-a",
            "harmony-entry:account-b"
        ])
        #expect(result.entries.allSatisfy { $0.customFields.first?.templateFieldId == "template_owner" })
    }

    @Test("Compare version classifies dominance and concurrent updates")
    func compareVersionClassifiesDominanceAndConcurrentUpdates() {
        #expect(VaultSyncMerger.compareVersion(local: ["A": 1], remote: ["A": 1]) == .equal)
        #expect(VaultSyncMerger.compareVersion(local: ["A": 2, "B": 1], remote: ["A": 1, "B": 1]) == .localDominates)
        #expect(VaultSyncMerger.compareVersion(local: ["A": 1], remote: ["A": 2]) == .remoteDominates)
        #expect(VaultSyncMerger.compareVersion(local: ["A": 2, "B": 1], remote: ["A": 1, "B": 2]) == .concurrent)
    }

    private func buildEntry(
        id: String,
        label: String,
        updatedBy: String,
        version: [String: Int],
        isDeleted: Bool = false
    ) -> VaultEntry {
        let now = Date(timeIntervalSince1970: 1_707_738_000)
        return VaultEntry(
            id: id,
            label: label,
            type: .credential,
            payload: .credential(
                CredentialPayload(
                    username: "user-\(id)",
                    password: "password-\(id)"
                )
            ),
            createdAt: now,
            updatedAt: now.addingTimeInterval(300),
            isDeleted: isDeleted,
            deletedAt: isDeleted ? now.addingTimeInterval(360) : nil,
            version: version,
            updatedBy: updatedBy
        )
    }
}
